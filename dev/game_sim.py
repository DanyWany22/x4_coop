"""
Stand-in for X4's Lua pipe client: opens the bridge's named pipe, sends snapshots, pings and one
chat line, and checks what comes back from the partner (fake_peer.py) through the bridge.

    game_sim.py <pipe_name> <seconds> [--gc] [--expect-nothing]

--gc              finish with the "garbage_collected" message SirNukes' Lua sends when it drops a pipe
--expect-nothing  pass only if no partner traffic arrives (e.g. wrong password)
"""
import ctypes
import sys
import time
from ctypes import wintypes

k = ctypes.WinDLL("kernel32", use_last_error=True)
k.CreateFileW.restype = wintypes.HANDLE
k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                          wintypes.DWORD, wintypes.HANDLE]
k.SetNamedPipeHandleState.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID, wintypes.LPVOID]
k.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
k.CloseHandle.argtypes = [wintypes.HANDLE]

name, secs = sys.argv[1], float(sys.argv[2])
expect_nothing = "--expect-nothing" in sys.argv
path = "\\\\.\\pipe\\" + name
for _ in range(100):
    h = k.CreateFileW(path, 0xC0000000, 0, None, 3, 0, None)
    if h != wintypes.HANDLE(-1).value:
        break
    time.sleep(0.1)
else:
    print("FAIL: could not open pipe, error", ctypes.get_last_error())
    sys.exit(1)
mode = wintypes.DWORD(0x2 | 0x1)  # message read mode + nowait, like the winpipe client
assert k.SetNamedPipeHandleState(h, ctypes.byref(mode), None, None), ctypes.get_last_error()
buf = ctypes.create_string_buffer(65536)


def write(msg):
    data, n = msg.encode(), wintypes.DWORD()
    assert k.WriteFile(h, data, len(data), ctypes.byref(n), None), ctypes.get_last_error()


def read():
    n = wintypes.DWORD()
    if k.ReadFile(h, buf, 65536, ctypes.byref(n), None):
        return buf.raw[:n.value].decode()
    if ctypes.get_last_error() == 232:  # ERROR_NO_DATA: nothing waiting
        return None
    raise OSError(ctypes.get_last_error(), "read")


t0 = time.monotonic()
seq, next_ping, chatted = 0, 0.0, False
got = {"W": 0, "N": 0, "S": 0, "Q": 0, "M": 0}
last_s, rtts, names = None, [], set()
while time.monotonic() - t0 < secs:
    now = time.monotonic() - t0
    seq += 1
    write("S|%d|%.4f|cluster_01_sector001_macro|ship_arg_s_fighter_01_a_macro|%.2f|0.00|5000.00|0.10000|0.00000|0.00000|100.00|0.00|0.00|Tester"
          % (seq, now, 1000 + 100 * now))
    if now >= next_ping:
        next_ping = now + 0.5
        write("P|%.4f" % now)
    if not chatted and now > 0.5:
        chatted = True
        write("M|Tester|hello partner")
    while True:
        m = read()
        if m is None:
            break
        got[m[0]] = got.get(m[0], 0) + 1
        if m[0] in "WNM":
            print("  game got:", m)
        if m[0] == "S":
            last_s = m
            names.add(m.split("|")[-1])
        if m[0] == "Q":
            rtts.append(now - float(m.split("|")[1]))
    time.sleep(0.05)
if "--gc" in sys.argv:
    write("garbage_collected")
k.CloseHandle(h)
print("counts:", got)
print("last snapshot:", last_s)
print("partners heard:", ",".join(sorted(names)) or "-")
if rtts:
    print("rtt ms: min %.1f max %.1f" % (min(rtts) * 1000, max(rtts) * 1000))
if expect_nothing:
    ok = got["W"] >= 1 and got["S"] == 0 and got["Q"] == 0 and got["M"] == 0
else:
    ok = got["W"] >= 1 and got["S"] > 10 and got["Q"] >= 1 and got["M"] >= 1
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
