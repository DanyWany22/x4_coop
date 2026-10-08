#!/usr/bin/env python3
"""
X4 memory demo, separate from the co-op mod: finds your credits in the running X4.exe's memory, reads them, and
writes a new amount, to show that reading and writing the game's memory can be done. The mod itself never does
this; it only uses the game's own scripting interfaces (README, "For reviewers"), and never loads this file.

    python x4_memory_demo.py            # X4 running with a save loaded; follow the prompts

How it finds them (a "value scan", the same technique as Cheat Engine):
  1. you type the credits the game shows. The tool scans X4's writable memory for that number as a 64-bit
     integer, both in whole credits and in hundredths, at 8-byte aligned addresses;
  2. you change your credits in the game (buy or sell anything) and type the new amount. Only the places
     that now hold it are kept. Repeat until one or two are left;
  3. read: each place's address, its 8 bytes and the value they hold;
  4. write, only if you confirm: an amount you choose, written only where the current amount still is, then
     read back. The game's own credits display shows the change. The tool offers to put the old amount back.

Use a throwaway save and don't save afterwards: a write in the wrong place can crash the game.
Windows only, standard library only, no administrator rights needed.
"""
import argparse
import ctypes
import re
import struct
import subprocess
import sys
import time
from ctypes import wintypes

PROCESS_VM_READ, PROCESS_VM_WRITE, PROCESS_VM_OPERATION, PROCESS_QUERY_INFORMATION = 0x10, 0x20, 0x8, 0x400
MEM_COMMIT = 0x1000
WRITABLE = {0x04, 0x08, 0x40, 0x80}  # PAGE_READWRITE, PAGE_WRITECOPY, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_WRITECOPY
PAGE_GUARD = 0x100
USER_SPACE_END = 1 << 47
CHUNK = 4 << 20
MAX_HITS = 200000
SCALES = {1: "credits", 100: "hundredths of a credit"}

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenProcess.restype = wintypes.HANDLE
k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.VirtualQueryEx.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
k32.ReadProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                  ctypes.POINTER(ctypes.c_size_t)]
k32.WriteProcessMemory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_size_t)]
k32.CloseHandle.argtypes = [wintypes.HANDLE]


class MemoryInfo(ctypes.Structure):  # MEMORY_BASIC_INFORMATION (64-bit)
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", wintypes.DWORD), ("PartitionId", wintypes.WORD),
                ("RegionSize", ctypes.c_size_t), ("State", wintypes.DWORD), ("Protect", wintypes.DWORD),
                ("Type", wintypes.DWORD)]


def find_pid(name):
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().strip('"').split('","')
        if len(parts) > 1 and parts[0].lower() == name.lower():
            return int(parts[1])
    return None


class Process:
    def __init__(self, pid):
        self.pid = pid
        access = PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_QUERY_INFORMATION
        self.handle = k32.OpenProcess(access, False, pid)
        if not self.handle:
            raise OSError(f"can't open process {pid} (Windows error {ctypes.get_last_error()})")

    def regions(self):
        """(base, size) of each committed, writable memory region."""
        info, address = MemoryInfo(), 0
        while address < USER_SPACE_END and k32.VirtualQueryEx(self.handle, ctypes.c_void_p(address),
                                                              ctypes.byref(info), ctypes.sizeof(info)):
            base, size = info.BaseAddress or 0, info.RegionSize
            if info.State == MEM_COMMIT and (info.Protect & 0xFF) in WRITABLE and not info.Protect & PAGE_GUARD:
                yield base, size
            address = base + size

    def read(self, address, size):
        buf, got = ctypes.create_string_buffer(size), ctypes.c_size_t()
        if not k32.ReadProcessMemory(self.handle, ctypes.c_void_p(address), buf, size, ctypes.byref(got)):
            return None
        return buf.raw[:got.value]

    def read_int64(self, address):
        data = self.read(address, 8)
        return struct.unpack("<q", data)[0] if data and len(data) == 8 else None

    def write_int64(self, address, value):
        data, done = struct.pack("<q", value), ctypes.c_size_t()
        return bool(k32.WriteProcessMemory(self.handle, ctypes.c_void_p(address), data, 8, ctypes.byref(done))) \
            and done.value == 8

    def close(self):
        k32.CloseHandle(self.handle)


def scan(proc, credits):
    """Every 8-byte aligned place holding credits (or credits x 100): {address: scale}."""
    patterns = {struct.pack("<q", credits * scale): scale for scale in SCALES}
    hits, scanned, started = {}, 0, time.time()
    for base, size in proc.regions():
        for offset in range(0, size, CHUNK):
            data = proc.read(base + offset, min(CHUNK, size - offset))
            if not data:
                continue
            scanned += len(data)
            for pattern, scale in patterns.items():
                i = data.find(pattern)
                while i != -1 and len(hits) < MAX_HITS:
                    if (base + offset + i) % 8 == 0:
                        hits[base + offset + i] = scale
                    i = data.find(pattern, i + 1)
    return hits, scanned, time.time() - started


def narrow(proc, hits, credits):
    return {a: s for a, s in hits.items() if proc.read_int64(a) == credits * s}


def show(proc, hits, limit=8):
    for address, scale in list(hits.items())[:limit]:
        data = proc.read(address, 8) or b""
        value = struct.unpack("<q", data)[0] if len(data) == 8 else None
        shown = f"{value // scale:,} Cr" if value is not None else "unreadable"
        print(f"   0x{address:016X}   bytes {data.hex(' ')}   = {value}  ({SCALES[scale]}: {shown})")
    if len(hits) > limit:
        print(f"   ... and {len(hits) - limit} more")


def amount(text):
    digits = re.sub(r"[^\d]", "", text or "")
    return int(digits) if digits else None


def ask(prompt):
    try:
        return input(prompt)
    except EOFError:
        return ""


def main(argv=None):
    p = argparse.ArgumentParser(description="Read and write your credits in X4's memory (a demo, not part of the mod)")
    p.add_argument("--process", default="X4.exe", help="process name (default X4.exe)")
    p.add_argument("--pid", type=int, help="process id instead of a name")
    p.add_argument("--credits", help="the credits the game shows now (else asked)")
    p.add_argument("--then", action="append", default=[], help="next amount after a change in game (repeatable)")
    p.add_argument("--write", help="amount to write (else asked)")
    p.add_argument("--yes", action="store_true", help="no questions: don't narrow further, write without asking")
    args = p.parse_args(argv)

    pid = args.pid or find_pid(args.process)
    if not pid:
        print(f"{args.process} is not running. Start X4 and load a save (a throwaway one) first.")
        return 1
    proc = Process(pid)
    print(f"Opened {args.process if not args.pid else 'process'} (pid {pid}) for reading and writing.")
    credits = amount(args.credits) or amount(ask("Credits the game shows now: "))
    if not credits or credits < 1000:
        print("Need an amount of at least 1,000 Cr (small numbers are everywhere in memory).")
        return 1
    hits, scanned, seconds = scan(proc, credits)
    print(f"Scanned {scanned / 1e9:.2f} GB of writable memory in {seconds:.1f} s: "
          f"{len(hits)} place(s) hold {credits:,} as credits or hundredths.")
    nexts = [amount(t) for t in args.then]
    while len(hits) > 2:
        if nexts:
            new = nexts.pop(0)
        elif args.yes:
            break
        else:
            new = amount(ask("Change your credits in the game (buy or sell anything), then type the new amount "
                             "(Enter to stop): "))
        if not new:
            break
        hits, credits = narrow(proc, hits, new), new
        print(f"{len(hits)} place(s) now hold {credits:,}.")
    if not hits:
        print("Not found. Check the amount (the exact number on the credits display) and try again.")
        return 1

    print("\nREAD: X4's memory at these addresses holds your credits right now:")
    show(proc, hits)
    new = amount(args.write) if args.write else amount(ask("\nType an amount to WRITE into X4's memory "
                                                           "(Enter to skip): "))
    if not new:
        print("Nothing written.")
        return 0
    if not args.yes and ask(f"Write {new:,} Cr into X4 at {len(hits)} place(s)? Use a throwaway save. [y/N] ") \
            .strip().lower() not in ("y", "yes"):
        print("Nothing written.")
        return 0

    def put(old, value):
        written = 0
        for address, scale in hits.items():
            if proc.read_int64(address) == old * scale and proc.write_int64(address, value * scale):
                written += 1
        return written

    written = put(credits, new)
    print(f"\nWRITE: {written} of {len(hits)} place(s) written. Read back:")
    show(proc, hits)
    print("Look at your credits in the game: it should now show " + f"{new:,} Cr.")
    if not args.yes and ask(f"Press Enter to put back {credits:,} Cr, or type keep: ").strip().lower() != "keep":
        print(f"Put back at {put(new, credits)} place(s).")
    proc.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
