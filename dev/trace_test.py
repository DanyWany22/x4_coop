"""
End-to-end test of the telemetry: two real bridges (host and joiner) recording --trace, two stand-ins for the
games flying different paths at 30 Hz (one reports a hit, the other a kill), then x4_coop_trace_report.py over
both traces must match the packets, find identical bytes and text on both sides, and see both ships.

    trace_test.py <udp port> [--keep DIR] [--overlay SECONDS] [--feed]     exit code 0 = pass

--keep DIR leaves the traces and the HTML report there; --overlay also opens the overlay window for about that
many seconds, following the host's trace, or with --feed started by the host's bridge (--overlay) as in play.
"""
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # run_tests.py starts Python isolated (-I), without the script's folder on the path
from share_test import Game  # noqa: E402
BRIDGE_DIR = os.path.join(HERE, "..", "bridge")
SECTOR = "cluster_14_sector001_macro"


def snapshot(seq, t, pos, yaw, vel, name, code, hull, shield):
    return (f"S|{seq}|{t:.4f}|{SECTOR}|ship_arg_s_fighter_01_a_macro|{pos[0]:.2f}|{pos[1]:.2f}|{pos[2]:.2f}"
            f"|{yaw:.5f}|0.00000|0.00000|{vel[0]:.2f}|{vel[1]:.2f}|{vel[2]:.2f}|{name}|{code}|{hull}|{shield}")


def main():
    port = int(sys.argv[1])
    keep = sys.argv[sys.argv.index("--keep") + 1] if "--keep" in sys.argv else None
    overlay_s = float(sys.argv[sys.argv.index("--overlay") + 1]) if "--overlay" in sys.argv else None
    feed = overlay_s and "--feed" in sys.argv
    folder = keep or tempfile.mkdtemp()
    os.makedirs(folder, exist_ok=True)
    host_trace, join_trace = os.path.join(folder, "host.jsonl"), os.path.join(folder, "join.jsonl")
    for path in (host_trace, join_trace):
        if os.path.exists(path):
            os.remove(path)
    py = [sys.executable, "-I"]
    bridge = py + [os.path.join(BRIDGE_DIR, "x4_coop_bridge.py"), "--password", "correct horse battery", "--any-client"]
    procs = [subprocess.Popen(bridge + ["--host", "--port", str(port), "--pipe", "x4c_tr_h", "--trace", host_trace]
                              + (["--overlay"] if feed else []),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True),
             subprocess.Popen(bridge + ["--join", f"127.0.0.1:{port}", "--pipe", "x4c_tr_j", "--trace", join_trace],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)]
    if overlay_s and not feed:
        procs.append(subprocess.Popen(py + [os.path.join(BRIDGE_DIR, "x4_coop_overlay.py"), "--follow", host_trace,
                                            "--exit-after", str(overlay_s)]))
    try:
        host, joiner = Game("x4c_tr_h"), Game("x4c_tr_j")
        deadline = time.time() + 10
        while time.time() < deadline and not (host.saw("N|partner connected") and joiner.saw("N|partner connected")):
            host.pump(), joiner.pump(), time.sleep(0.05)
        start, seq = time.time(), 0
        hit = killed = False
        duration = max(5.0, (overlay_s or 0) - 1)
        while time.time() - start < duration:
            t = time.time() - start
            seq += 1
            a = 0.4 * t  # host circles at 200 m/s; the joiner flies a weaving line at ~150 m/s
            host.write(snapshot(seq, 1000 + t, (500 * math.cos(a), 20, 500 * math.sin(a)), a,
                                (-200 * math.sin(a), 0, 200 * math.cos(a)), "Host Nemesis", "HST-001",
                                100 if t < 2 else 87, 100))
            joiner.write(snapshot(seq, 2500 + 0.98 * t, (300 + 40 * math.sin(2 * t), -10, -800 + 150 * t), 0.0,
                                  (80 * math.cos(2 * t), 0, 150), "Joiner Elite", "JNR-002", 100, 64))
            if t > 2 and not hit:
                hit = True
                host.write(f"D|XEN-123|ship_xen_m_fighter_01_a_macro|{SECTOR}|63.50")
            if t > 3 and not killed:
                killed = True
                joiner.write(f"K|XEN-456|ship_xen_m_fighter_01_a_macro|{SECTOR}")
            host.pump(), joiner.pump()
            time.sleep(1 / 30)
        time.sleep(1.5)  # let the bridges flush their traces (once a second)
    finally:
        for p in procs[:2]:
            p.terminate()
        logs = [p.communicate(timeout=5)[0] for p in procs[:2]]
        if len(procs) > 2:
            procs[2].wait(timeout=overlay_s + 10)

    def events(path):
        with open(path, encoding="utf-8") as fh:
            return [json.loads(line) for line in fh if line.endswith("\n")]
    he, je = events(host_trace), events(join_trace)
    html_path = os.path.join(folder, "report.html")
    rep = subprocess.run(py + [os.path.join(BRIDGE_DIR, "x4_coop_trace_report.py"), host_trace, join_trace,
                               "--html", html_path], capture_output=True, text=True, timeout=60)
    out = rep.stdout
    arrivals = [(int(a), int(b)) for a, b in re.findall(r"(\d+) of (\d+) sent arrived", out)]
    same = re.search(r"text identical on both sides: (\d+) of (\d+); recorded wire bytes identical: (\d+) of (\d+)", out)
    checks = {
        "both traces record the socket binding": all(any(e["ev"] == "start" and e.get("udp_bind") for e in ev)
                                                    for ev in (he, je)),
        "both bridges measured a round trip": all(any(e["ev"] == "peer" and e.get("rtt_ms") is not None for e in ev)
                                                 for ev in (he, je)),
        "report runs": rep.returncode == 0,
        "100+ datagrams matched each way, 99%+ arrived": len(arrivals) == 2 and all(
            a >= 100 and a >= 0.99 * b for a, b in arrivals),
        "same text and bytes on both machines": bool(same) and same.group(1) == same.group(2)
                                                and same.group(3) == same.group(4),
        "distinct processes": "distinct processes: yes" in out,
        "hit and kill seen arriving": len(re.findall(r"\b[DK]\b .* arrived after", out)) == 2,
        "both ships in the side-by-side table": "A: Host Nemesis" in out and "B: Joiner Elite" in out
                                                  and out.count(" | ") >= 20,
        "game state example shown as bytes": "message  S|" in out and "as text  X4C2 " in out,
        "html report with charts": os.path.exists(html_path) and "<svg" in open(html_path, encoding="utf-8").read(),
    }
    for name, passed in checks.items():
        print(("ok   " if passed else "FAIL ") + name)
    ok = all(checks.values())
    if not ok or keep:
        print(out)
    if not ok:
        print(rep.stderr + "\nhost bridge:\n" + logs[0] + "\njoin bridge:\n" + logs[1])
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
