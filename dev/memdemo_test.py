"""
Test of demo/x4_memory_demo.py against a stand-in process (not X4): the stand-in keeps a "credits" amount in its
memory as a 64-bit integer in hundredths, like a game might, and reports when it changes. The demo must find it
by value, narrow it after the stand-in changes it, read it, write a new amount and see the stand-in notice.

    memdemo_test.py     exit code 0 = pass
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STAND_IN = r"""
import ctypes, sys, time
credits = ctypes.c_int64(7364528193 * 100)
print(ctypes.addressof(credits), flush=True)
seen = credits.value
for line in sys.stdin:                      # "spend N": the game changing the amount itself
    if line.startswith("spend"):
        credits.value -= int(line.split()[1]) * 100
        seen = credits.value
        print("spent", flush=True)
    elif line.startswith("check"):
        print("changed" if credits.value != seen else "unchanged", credits.value // 100, flush=True)
"""


def main():
    sys.path.insert(0, os.path.join(HERE, "..", "demo"))
    import x4_memory_demo as demo_mod
    stand_in = subprocess.Popen([sys.executable, "-I", "-c", STAND_IN], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, text=True)

    def tell(line):
        stand_in.stdin.write(line + "\n")
        stand_in.stdin.flush()
        return stand_in.stdout.readline().split()
    try:
        address = int(stand_in.stdout.readline())
        proc = demo_mod.Process(stand_in.pid)
        hits = demo_mod.scan(proc, 7364528193)[0]
        tell("spend 1500")  # the "game" changes the amount between scans
        narrowed = demo_mod.narrow(proc, hits, 7364526693)
        proc.close()
        demo = subprocess.run([sys.executable, "-I", os.path.join(HERE, "..", "demo", "x4_memory_demo.py"),
                               "--pid", str(stand_in.pid), "--credits", "7,364,526,693", "--write", "4242424242",
                               "--yes"], capture_output=True, text=True, timeout=60)
        verdict = tell("check")
    finally:
        stand_in.kill()
    out = demo.stdout
    found = re.findall(r"0x([0-9A-F]{16})", out)
    checks = {
        "scan finds the amount at the stand-in's address": hits.get(address) == 100,
        "narrowing after a change keeps it": address in narrowed and len(narrowed) <= len(hits),
        "demo ran": demo.returncode == 0,
        "read shows that address and its bytes": f"{address:016X}" in found and "hundredths of a credit" in out,
        "write reported": re.search(r"WRITE: [1-9]\d* of \d+ place\(s\) written", out) is not None,
        "the stand-in saw its own memory change": verdict[:2] == ["changed", "4242424242"],
    }
    for name, passed in checks.items():
        print(("ok   " if passed else "FAIL ") + name)
    ok = all(checks.values())
    if not ok:
        print(out + demo.stderr + f"\nstand-in address {address:016X}, says {verdict}")
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
