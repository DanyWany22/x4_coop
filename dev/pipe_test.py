"""
End-to-end test of the mod's own pipe client: the "own pipe client" block of ui/x4_coop.lua runs inside X4's own
LuaJIT (lua51_64.dll, through run_lua.py) and talks to a real bridge, which relays to a stand-in partner
(fake_peer.py) over UDP. The Lua side must open the pipe through kernel32 via FFI, receive the bridge's
greeting, get a ping answered and a chat reply from the partner, and notice when the bridge goes away.

    pipe_test.py <udp port>     exit code 0 = pass
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..")

HARNESS = """
local ffi = require("ffi")
local C = ffi.C
%s
ffi.cdef[[ void Sleep(uint32_t ms); ]]
local PIPE = "x4c_pipe_t"
local got, gone = {}, false
local function reader(msg)
	if msg == "ERROR" then gone = true else got[#got + 1] = msg end
end
print("available " .. tostring(OwnPipe.available()))
local opened = false
for _ = 1, 100 do  -- the bridge may still be starting
	gone = false
	OwnPipe.Schedule_Read(PIPE, reader)
	if not gone then opened = true break end
	C.Sleep(100)
end
print("opened " .. tostring(opened))
for i = 1, 900 do  -- 9 s; the test stops the bridge after about 5
	OwnPipe.poll()
	if i == 150 then OwnPipe.Schedule_Write(PIPE, nil, "P|123.5") end
	if i == 151 then OwnPipe.Schedule_Write(PIPE, nil, "M|Lua test|hello from X4's LuaJIT") end
	if gone then print("bridge gone after " .. i * 10 .. " ms") break end
	C.Sleep(10)
end
for _, msg in ipairs(got) do print("got " .. msg) end
"""


def main():
    port = int(sys.argv[1])
    with open(os.path.join(MOD, "ui", "x4_coop.lua"), encoding="utf-8") as fh:
        block = re.search(r"-- BEGIN own pipe client.*?\n(.*)-- END own pipe client", fh.read(), re.S).group(1)
    script = os.path.join(tempfile.mkdtemp(), "pipe_test.lua")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write(HARNESS % block)
    py = [sys.executable, "-I"]
    bridge = subprocess.Popen(py + [os.path.join(MOD, "bridge", "x4_coop_bridge.py"), "--host", "--port", str(port),
                                    "--pipe", "x4c_pipe_t", "--password", "pipe test password", "--any-client"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    peer = subprocess.Popen(py + [os.path.join(HERE, "fake_peer.py"), "--join", f"127.0.0.1:{port}",
                                  "--password", "pipe test password", "--name", "Peer"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lua = subprocess.Popen(py + [os.path.join(HERE, "run_lua.py"), script], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(5)
        bridge.terminate()
        out = lua.communicate(timeout=30)[0]
    finally:
        for p in (bridge, peer, lua):
            if p.poll() is None:
                p.terminate()
        logs = [p.communicate(timeout=5)[0] for p in (bridge, peer)]
    got = [line[4:] for line in out.splitlines() if line.startswith("got ")]
    checks = {
        "kernel32 pipe functions reachable through FFI": "available true" in out,
        "pipe opened": "opened true" in out,
        "bridge greeted the game": any(m.startswith("W|bridge ready") for m in got) and "R|host" in got,
        "partner connected": "N|partner connected" in got,
        "ping answered across the network": "Q|123.5" in got,
        "chat reply from the partner": any(m.startswith("M|Peer|") for m in got),
        "closed pipe noticed": "bridge gone after" in out,
        "bridge saw X4's side": "X4 connected" in logs[0],
    }
    for name, passed in checks.items():
        print(("ok   " if passed else "FAIL ") + name)
    ok = all(checks.values())
    if not ok:
        print("lua:\n" + out + "\nbridge:\n" + logs[0] + "\npeer:\n" + logs[1])
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
