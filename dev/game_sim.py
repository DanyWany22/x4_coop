"""Stand-in for X4's Lua pipe client: connects to the named pipe, sends snapshots and pings,
prints/validates what comes back. usage: game_sim.py <pipe_name> <seconds> [--gc]"""
import ctypes, sys, time, math
from ctypes import wintypes
k = ctypes.WinDLL("kernel32", use_last_error=True)
k.CreateFileW.restype = wintypes.HANDLE
k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
k.SetNamedPipeHandleState.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID, wintypes.LPVOID]
k.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k.CloseHandle.argtypes = [wintypes.HANDLE]
name, secs = sys.argv[1], float(sys.argv[2])
path = chr(92) * 2 + "." + chr(92) + "pipe" + chr(92) + name
h = None
for _ in range(100):
    h = k.CreateFileW(path, 0xC0000000, 0, None, 3, 0, None)
    if h != wintypes.HANDLE(-1).value: break
    time.sleep(0.1)
else:
    print("FAIL: could not open pipe, error", ctypes.get_last_error()); sys.exit(1)
mode = wintypes.DWORD(0x2 | 0x1)  # message read mode + nowait, like the winpipe client
assert k.SetNamedPipeHandleState(h, ctypes.byref(mode), None, None), ctypes.get_last_error()
buf = ctypes.create_string_buffer(65536)
def write(msg):
    d = msg.encode(); n = wintypes.DWORD()
    assert k.WriteFile(h, d, len(d), ctypes.byref(n), None), ctypes.get_last_error()
def read():
    n = wintypes.DWORD()
    if k.ReadFile(h, buf, 65536, ctypes.byref(n), None): return buf.raw[:n.value].decode()
    e = ctypes.get_last_error()
    if e == 232: return None
    raise OSError(e, "read")
t0 = time.monotonic(); seq = 0; got = {"W": 0, "N": 0, "S": 0, "P": 0, "Q": 0}; last_s = None; rtts = []
next_ping = 0
while time.monotonic() - t0 < secs:
    now = time.monotonic() - t0
    seq += 1
    x = 1000 + 100 * now
    write("S|%d|%.4f|cluster_01_sector001_macro|ship_arg_s_fighter_01_a_macro|%.2f|0.00|5000.00|0.10000|0.00000|0.00000|100.00|0.00|0.00|Tester" % (seq, now, x))
    if now >= next_ping:
        next_ping = now + 0.5; write("P|%.4f" % now)
    while True:
        m = read()
        if m is None: break
        got[m[0]] = got.get(m[0], 0) + 1
        if m[0] in "WN": print("  game got:", m)
        if m[0] == "S": last_s = m
        if m[0] == "Q": rtts.append(now - float(m.split("|")[1]))
    time.sleep(0.05)
if "--gc" in sys.argv:
    write("garbage_collected")
k.CloseHandle(h)
print("counts:", got)
print("last snapshot:", last_s)
if rtts: print("rtt ms: min %.1f max %.1f" % (min(rtts) * 1000, max(rtts) * 1000))
ok = got["W"] >= 1 and got["S"] > 10 and got["Q"] >= 1
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
