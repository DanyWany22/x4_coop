"""
End-to-end test of the save handoff: two real bridges on this PC (host and joiner), and two stand-ins for
the games on their pipes. The host "game" asks to share, then writes a save (as SaveGame would); the joiner's
bridge must fetch it into the joiner's save folder, keep the old quicksave as a backup and tell its game.

    share_test.py <udp port>        exit code 0 = pass
"""
import ctypes
import glob
import gzip
import os
import subprocess
import sys
import tempfile
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


class Game:
    """Minimal pipe client, like the game's: message mode, non-blocking reads."""

    def __init__(self, name):
        path = "\\\\.\\pipe\\" + name
        for _ in range(100):
            self.h = k.CreateFileW(path, 0xC0000000, 0, None, 3, 0, None)
            if self.h != wintypes.HANDLE(-1).value:
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"FAIL: could not open {path}")
        mode = wintypes.DWORD(0x2 | 0x1)
        k.SetNamedPipeHandleState(self.h, ctypes.byref(mode), None, None)
        self.buf = ctypes.create_string_buffer(65536)
        self.got = []

    def write(self, msg):
        data, n = msg.encode(), wintypes.DWORD()
        k.WriteFile(self.h, data, len(data), ctypes.byref(n), None)

    def pump(self):
        n = wintypes.DWORD()
        while k.ReadFile(self.h, self.buf, 65536, ctypes.byref(n), None):
            self.got.append(self.buf.raw[:n.value].decode())

    def saw(self, prefix):
        return any(m.startswith(prefix) for m in self.got)


def main():
    port = int(sys.argv[1])
    here = os.path.dirname(os.path.abspath(__file__))
    bridge = os.path.join(here, "..", "bridge", "x4_coop_bridge.py")
    py = [sys.executable, "-I", bridge, "--password", "pw", "--any-client"]
    host_dir, join_dir = tempfile.mkdtemp(), tempfile.mkdtemp()
    with open(os.path.join(join_dir, "quicksave.xml.gz"), "wb") as fh:
        fh.write(gzip.compress(b"the joiner's old quicksave"))

    procs = [subprocess.Popen(py + ["--host", "--port", str(port), "--pipe", "x4c_share_h"], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True),
             subprocess.Popen(py + ["--join", f"127.0.0.1:{port}", "--pipe", "x4c_share_j"], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)]
    ok = False
    try:
        host, joiner = Game("x4c_share_h"), Game("x4c_share_j")
        joiner.write("X|savedir|" + join_dir)
        deadline = time.time() + 10
        while time.time() < deadline and not (host.saw("N|partner connected") and joiner.saw("N|partner connected")):
            host.pump(), joiner.pump(), time.sleep(0.05)

        host.write("X|share|" + host_dir + "|quicksave.xml.gz")
        time.sleep(0.3)
        save = gzip.compress(os.urandom(3 * 1024 * 1024))  # what SaveGame writes, a moment later
        with open(os.path.join(host_dir, "quicksave.xml.gz"), "wb") as fh:
            fh.write(save)

        deadline = time.time() + 30
        while time.time() < deadline and not joiner.saw("X|received|quicksave"):
            host.pump(), joiner.pump(), time.sleep(0.05)
        time.sleep(0.5)
        host.pump(), joiner.pump()

        with open(os.path.join(join_dir, "quicksave.xml.gz"), "rb") as fh:
            arrived = fh.read()
        backups = glob.glob(os.path.join(join_dir, "quicksave.xml.gz.bak-*"))
        old = gzip.decompress(open(backups[0], "rb").read()) if backups else b""
        checks = {
            "joiner told": joiner.saw("X|received|quicksave"),
            "file identical": arrived == save,
            "old quicksave backed up": old == b"the joiner's old quicksave",
            "host told it was sent": any("save sent to your partner" in m for m in host.got),
        }
        for name, passed in checks.items():
            print(("ok   " if passed else "FAIL ") + name)
        ok = all(checks.values())
    finally:
        for p in procs:
            p.terminate()
        logs = [p.communicate(timeout=5)[0] for p in procs]
    if not ok:
        print("host bridge:\n" + logs[0] + "\njoin bridge:\n" + logs[1])
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
