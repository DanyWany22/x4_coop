#!/usr/bin/env python3
"""
Offline checks for X4 Co-op. No game session needed; run after every change:

    python extensions/x4_coop/dev/run_tests.py

1. md/*.xml validated against the game's own md.xsd (pulled from the .cat archives; needs lxml)
2. ui/x4_coop.lua flown through every sim.lua scenario inside X4's own LuaJIT (lua51_64.dll)
3. the network bridge end to end: x4_coop_bridge.py + fake_peer.py + game_sim.py (stands in
   for the game's pipe client)
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
GAME = MOD.parents[1]
sys.path.insert(0, str(DEV))
import catx  # noqa: E402
import run_lua  # noqa: E402

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
    catx.extract(tmp, r"^libraries/(md|common)\.xsd$", cats)
    schema = etree.XMLSchema(etree.parse(str(Path(tmp) / "libraries" / "md.xsd")))
    for path in sorted((MOD / "md").glob("*.xml")):
        doc = etree.parse(str(path))
        ok = schema.validate(doc)
        check(f"md schema: {path.name}", ok, "; ".join(f"line {e.line}: {e.message}" for e in schema.error_log)[:500])


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


def test_bridge():
    port, pipe = free_udp_port(), "x4_coop_selftest"
    py = [sys.executable, "-I"]
    bridge = subprocess.Popen(py + [str(MOD / "bridge" / "x4_coop_bridge.py"), "--host", "--port", str(port), "--pipe", pipe],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    peer = subprocess.Popen(py + [str(MOD / "bridge" / "fake_peer.py"), "--join", f"127.0.0.1:{port}", "--delay", "0.02"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    try:
        time.sleep(1.0)
        runs = [("bridge: game connects, gets echo + pong", []),
                ("bridge: reconnect after game releases pipe", ["--gc"]),
                ("bridge: reconnect again", [])]
        for name, extra in runs:
            r = subprocess.run(py + [str(DEV / "game_sim.py"), pipe, "3"] + extra, capture_output=True, text=True, timeout=30)
            summary = " ".join(l for l in r.stdout.splitlines() if l.startswith(("counts", "rtt")))
            check(name, r.returncode == 0, summary)
    finally:
        for p in (peer, bridge):
            p.terminate()
        log = bridge.communicate(timeout=5)[0]
    if not all(results[-3:]):
        print("      bridge log:\n      " + "\n      ".join(log.splitlines()))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        test_md_schema(tmp)
        test_lua(tmp)
    test_bridge()
    failed = results.count(False)
    print(f"\n{len(results) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
