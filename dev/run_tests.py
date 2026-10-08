#!/usr/bin/env python3
"""
Offline checks for X4 Co-op. No game session needed; run after every change:

    python extensions/x4_coop/dev/run_tests.py [--quick]    (--quick skips the slow aiscripts schema)

1. md/*.xml and aiscripts/*.xml validated against the game's own schemas (from the .cat archives; needs lxml)
2. ui/x4_coop.lua flown through every sim.lua scenario inside X4's own LuaJIT (lua51_64.dll)
3. the network bridge end to end: x4_coop_bridge.py + fake_peer.py + game_sim.py (stands in
   for the game's pipe client), pipe_test.py (the mod's own pipe client inside X4's LuaJIT, through a real
   bridge), share_test.py (save handoff between two real bridges) and trace_test.py (two bridges' telemetry
   traces, compared by x4_coop_trace_report.py)
"""
import glob
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEV = Path(__file__).resolve().parent
MOD = DEV.parent
sys.path.insert(0, str(DEV))
import catx  # noqa: E402
import run_lua  # noqa: E402
GAME = run_lua.GAME_DIR  # set X4_GAME_DIR when running from a checkout outside the game folder

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def test_md_schema(tmp):
    try:
        from lxml import etree
    except ImportError:
        print("SKIP  md schema validation (pip install lxml to enable)")
        return
    cats = sorted(glob.glob(str(GAME / "[0-9][0-9].cat")))
    catx.extract(tmp, r"^libraries/(md|common|aiscripts)\.xsd$", cats)
    folders = (("md", "md.xsd"),) if "--quick" in sys.argv else (("md", "md.xsd"), ("aiscripts", "aiscripts.xsd"))
    for folder, xsd in folders:
        paths = sorted((MOD / folder).glob("*.xml"))
        if not paths:
            continue
        schema = etree.XMLSchema(etree.parse(str(Path(tmp) / "libraries" / xsd)))  # aiscripts.xsd takes a minute or two
        for path in paths:
            ok = schema.validate(etree.parse(str(path)))
            check(f"{folder} schema: {path.name}", ok, "; ".join(f"line {e.line}: {e.message}" for e in schema.error_log)[:500])


def test_lua(tmp):
    mod_lua = MOD / "ui" / "x4_coop.lua"
    listing = Path(tmp) / "scenarios.txt"
    ok, err = run_lua.run(DEV / "sim.lua", {"MOD": mod_lua, "OUT": listing, "SCENARIO": "list"})
    if not ok:
        check("lua simulator", False, err)
        return
    for scenario in listing.read_text().split():
        out = Path(tmp) / f"sim_{scenario}.txt"
        ok, err = run_lua.run(DEV / "sim.lua", {"MOD": mod_lua, "OUT": out, "SCENARIO": scenario})
        text = out.read_text() if out.exists() else ""
        passed = ok and text.rstrip().endswith("RESULT: PASS")
        detail = err or next((l.replace("position error (m): ", "pos ") for l in text.splitlines() if l.startswith("position")), "")
        check(f"lua sim: {scenario}", passed, detail)
        if not passed and text:
            print("      " + "\n      ".join(text.splitlines()[-12:]))


def free_udp_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PY = [sys.executable, "-I"]


def bridge_session(bridge_args, peers, runs):
    """Start a bridge and fake peers (each started after the previous one has connected), then
    run game_sim once per (name, extra args, check) in runs. Returns the bridge log."""
    port, pipe = free_udp_port(), "x4_coop_selftest"
    if "--strict" in bridge_args:
        bridge_args = [a for a in bridge_args if a != "--strict"]
    else:
        bridge_args = ["--any-client"] + bridge_args  # game_sim.py is python.exe, not X4.exe
    if "--password" not in bridge_args:
        bridge_args = ["--no-password"] + bridge_args
    procs = [subprocess.Popen(PY + [str(MOD / "bridge" / "x4_coop_bridge.py"), "--host", "--port", str(port), "--pipe", pipe] + bridge_args,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)]
    ok_before = len(results)
    try:
        for peer_args in peers:
            time.sleep(0.6)
            procs.append(subprocess.Popen(PY + [str(DEV / "fake_peer.py"), "--join", f"127.0.0.1:{port}"] + peer_args,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT))
        time.sleep(1.0)
        for name, extra, extra_check in runs:
            r = subprocess.run(PY + [str(DEV / "game_sim.py"), pipe, "3"] + extra, capture_output=True, text=True, timeout=30)
            summary = " ".join(l for l in r.stdout.splitlines() if l.startswith(("counts", "rtt", "partners", "dropped")))
            check(name, r.returncode == 0 and extra_check(r.stdout), summary)
    finally:
        for p in reversed(procs):
            p.terminate()
        log = procs[0].communicate(timeout=5)[0]
    if not all(results[ok_before:]):
        print("      bridge log:\n      " + "\n      ".join(log.splitlines()))
    return log


def test_codec():
    sys.path.insert(0, str(MOD / "bridge"))
    import x4_coop_bridge as bridge
    a, b = bridge.Codec("s3cret"), bridge.Codec("s3cret")
    first = a.seal("K|ABC-1|m|s")
    check("codec: signed message accepted", b.open(first) == "K|ABC-1|m|s")
    check("codec: replay rejected", b.open(first) is None and b.last_reject == "replayed")
    m2, m3 = a.seal("S|2"), a.seal("S|3")
    check("codec: reordered datagrams each accepted once",
          b.open(m3) == "S|3" and b.open(m2) == "S|2" and b.open(m2) is None)
    good = __import__("gzip").compress(b"x" * 100000)
    check("bridge: gzip completeness check", bridge.gzip_complete(good) and not bridge.gzip_complete(good[:-10]))
    check("codec: message is encrypted", b"ABC-1" not in first and b"K|" not in first)
    tampered = first[:-1] + bytes([first[-1] ^ 1])
    check("codec: tampered message rejected", bridge.Codec("s3cret").open(tampered) is None)
    c = bridge.Codec("s3cret")
    check("codec: other bridge version named",
          c.open(b"X4C1 " + first[len(bridge.MAGIC):]) is None and "version" in c.last_reject)
    old = bridge.Codec("s3cret")
    old_time = bridge.time.time
    bridge.time.time = lambda: old_time() - 600
    stale = old.seal("D|ABC-1|m|s|50")
    bridge.time.time = old_time
    check("codec: ten-minute-old message rejected", b.open(stale) is None and "old" in b.last_reject)
    check("codec: wrong password rejected", bridge.Codec("other").open(a.seal("P|1")) is None)
    check("codec: no password is plain", bridge.Codec("").open(bridge.Codec("").seal("P|1")) == "P|1")
    r = subprocess.run(PY + [str(MOD / "bridge" / "x4_coop_bridge.py"), "--host", "--pipe", "x4_coop_nopw"],
                       capture_output=True, text=True, timeout=30)
    check("bridge: refuses to run without a password", r.returncode != 0 and "--password" in r.stderr)


def test_bridge():
    anything = lambda out: True  # noqa: E731
    bridge_session([], [["--delay", "0.02"]], [
        ("bridge: game connects, gets echo, pong and chat reply", [], anything),
        ("bridge: reconnect after game releases pipe", ["--gc"], anything),
        ("bridge: reconnect again", [], anything),
    ])
    bridge_session(["--password", "s3cret"], [["--password", "s3cret"]], [
        ("bridge: matching password", [], anything),
    ])
    log = bridge_session(["--password", "s3cret"], [["--password", "wrong"]], [
        ("bridge: wrong password delivers nothing", ["--expect-nothing"], anything),
    ])
    check("bridge: wrong password is logged", "rejected packets" in log)
    bridge_session([], [["--inject", "R|join", "--inject", "W|evil", "--inject", "N|evil"]], [
        ("bridge: partner cannot send bridge-only messages",
         [], lambda out: "'R': 1," in out and "evil" not in out),
    ])
    log = bridge_session(["--strict"], [[]], [
        ("bridge: refuses a pipe client that is not X4.exe", ["--expect-rejected"], anything),
    ])
    check("bridge: refusal is logged", "only X4.exe may connect" in log)
    bridge_session([], [["--name", "First"], ["--name", "Intruder"]], [
        ("bridge: host ignores a second partner", [], lambda out: "partners heard: First" in out),
    ])


def main():
    with tempfile.TemporaryDirectory() as tmp:
        test_md_schema(tmp)
        test_lua(tmp)
    test_codec()
    test_bridge()
    r = subprocess.run(PY + [str(DEV / "share_test.py"), str(free_udp_port())], capture_output=True, text=True, timeout=120)
    check("bridge: host's save reaches the joiner (backup kept)", r.returncode == 0,
          " ".join(l.strip() for l in r.stdout.splitlines() if l.startswith(("ok", "FAIL"))))
    r = subprocess.run(PY + [str(DEV / "pipe_test.py"), str(free_udp_port())], capture_output=True, text=True,
                       timeout=120)
    check("pipe: the mod's own pipe client, in X4's LuaJIT, through a real bridge", r.returncode == 0,
          " ".join(l.strip() for l in r.stdout.splitlines() if l.startswith("FAIL")) or "")
    r = subprocess.run(PY + [str(DEV / "memdemo_test.py")], capture_output=True, text=True, timeout=120)
    check("memory demo: finds, reads and writes a value in another process (stand-in, not X4)", r.returncode == 0,
          " ".join(l.strip() for l in r.stdout.splitlines() if l.startswith("FAIL")) or "")
    r = subprocess.run(PY + [str(DEV / "trace_test.py"), str(free_udp_port())], capture_output=True, text=True,
                       timeout=120, cwd=DEV)
    check("telemetry: two bridges' traces match packet for packet (report, HTML)", r.returncode == 0,
          " ".join(l.strip() for l in r.stdout.splitlines() if l.startswith("FAIL")) or "")
    failed = results.count(False)
    print(f"\n{len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
