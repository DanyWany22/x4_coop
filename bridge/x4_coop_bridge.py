#!/usr/bin/env python3
"""
X4 Co-op network bridge:  X4 <-> named pipe <-> UDP <-> your partner's bridge <-> their X4.

Each player runs one bridge on the same PC as their game (start it before or after X4;
it waits for the game and reconnects after reloads):

    python x4_coop_bridge.py --host                   # wait for a partner on UDP 47810
    python x4_coop_bridge.py --join 203.0.113.7       # connect to a host (port defaults to 47810)
    python x4_coop_bridge.py --peer 198.51.100.4 --role host  # both name each other (no forwarding)

Only the host needs to be reachable: on the same LAN, on a VPN such as Tailscale/ZeroTier, or over
the internet with UDP and TCP port 47810 forwarded to the host's PC. Both sides use the same
--password: it encrypts and signs everything, so nobody else can read or forge the traffic.
Standard library only: Windows, Python 3.8+.

X4 reaches this pipe with the mod's own pipe client (Windows' pipe functions through LuaJIT's FFI, in
ui/x4_coop.lua), or with SirNukes' Mod Support APIs as a fallback.
Datagrams are b"X4C2 " + header + one encrypted pipe message (see Codec); the message format is
documented in ui/x4_coop.lua. "H" keepalives are handled here and never reach the game.
A host serves one partner at a time and takes a new one only after the current one goes silent.
On connect the game is told its role ("R|host" / "R|join"): the host's save is the shared world.
"X|..." messages are the bridges' own: the save handoff (see SaveShare), never forwarded to a game.

Telemetry (see Telemetry): --trace records the socket bindings and every datagram as JSON lines, --overlay
shows them live over the game (x4_coop_overlay.py), and x4_coop_trace_report.py lines up two machines' traces.
"""
import argparse
import ctypes
import functools
import hashlib
import hmac
import json
import os
import platform
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import zlib
from ctypes import wintypes

MAGIC = b"X4C2 "        # X4C1 was the unencrypted format; the two don't talk to each other
KDF_SALT = b"x4coop bridge v2"
SHORT_PASSWORD = 12      # below this, warn: fine on a LAN or VPN, weak on the open internet
DEFAULT_PORT = 47810
BUFFER_SIZE = 64 * 1024
KEEPALIVE_S = 1.0
PARTNER_TIMEOUT_S = 10.0
STATS_EVERY_S = 30.0
MAX_PACKETS_PER_S = 200  # a partner sends ~22/s; anything far above that is dropped
TRACE_HEX_BYTES = 64     # telemetry: bytes of each datagram shown in hex (--trace-bytes; 0 = all)
TRACE_DROPS_PER_S = 10   # telemetry: rejected/ignored/flooded datagrams recorded per second at most
FROM_PARTNER = set("SPQMLKDFBECTVUZOYGJIbscrameqpnlwghdft")  # message kinds a partner may send; R, W and N only come from this bridge

# Win32 named pipe API through ctypes, mirroring the parameters SirNukes' own server uses.
PIPE_ACCESS_DUPLEX = 0x3
PIPE_TYPE_MESSAGE = 0x4
PIPE_READMODE_MESSAGE = 0x2
PIPE_NOWAIT = 0x1
PIPE_REJECT_REMOTE_CLIENTS = 0x8
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
ERROR_BROKEN_PIPE = 109
ERROR_NO_DATA = 232
ERROR_PIPE_NOT_CONNECTED = 233
ERROR_PIPE_CONNECTED = 535
ERROR_PIPE_LISTENING = 536
INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateNamedPipeW.restype = wintypes.HANDLE
kernel32.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
kernel32.ConnectNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID]
kernel32.DisconnectNamedPipe.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                              ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                               ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel32.GetNamedPipeClientProcessId.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.ULONG)]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                ctypes.POINTER(wintypes.DWORD)]


class PipeClosed(Exception):
    pass


class GamePipe:
    """Non-blocking, single-client, message-mode pipe server that X4's Lua connects to."""

    def __init__(self, name):
        self.path = "\\\\.\\pipe\\" + name
        self.handle = None
        self.connected = False
        self.buf = ctypes.create_string_buffer(BUFFER_SIZE)

    def _create(self):
        # PIPE_NOWAIT on our end only: connect/read/write return at once, so the loop never stalls.
        # The client end keeps its own (message) mode.
        # PIPE_REJECT_REMOTE_CLIENTS: only processes on this PC; named pipes otherwise accept network clients.
        h = kernel32.CreateNamedPipeW(self.path, PIPE_ACCESS_DUPLEX,
                                      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                      1, BUFFER_SIZE, BUFFER_SIZE, 300, None)
        if h == INVALID_HANDLE_VALUE:
            err = ctypes.get_last_error()
            raise OSError(err, f"CreateNamedPipe failed for {self.path} (error {err}); is another bridge running?")
        self.handle = h

    def poll_connect(self):
        """True once the game has opened the pipe."""
        if self.handle is None:
            self._create()
        if kernel32.ConnectNamedPipe(self.handle, None):
            self.connected = True
        else:
            err = ctypes.get_last_error()
            if err == ERROR_PIPE_CONNECTED:
                self.connected = True
            elif err == ERROR_NO_DATA:
                self.close()  # a client came and went before we noticed; start over
            elif err != ERROR_PIPE_LISTENING:
                raise OSError(err, f"ConnectNamedPipe failed (error {err})")
        return self.connected

    def client(self):
        """(pid, executable path) of the connected process; path is None if it can't be read."""
        pid = wintypes.ULONG(0)
        if not kernel32.GetNamedPipeClientProcessId(self.handle, ctypes.byref(pid)):
            return None, None
        proc = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
        if not proc:
            return pid.value, None
        try:
            buf, size = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
            ok = kernel32.QueryFullProcessImageNameW(proc, 0, buf, ctypes.byref(size))
            return pid.value, buf.value if ok else None
        finally:
            kernel32.CloseHandle(proc)

    def read(self):
        """Next message from the game, or None if there is none. Raises PipeClosed."""
        n = wintypes.DWORD(0)
        if not kernel32.ReadFile(self.handle, self.buf, BUFFER_SIZE, ctypes.byref(n), None):
            err = ctypes.get_last_error()
            if err == ERROR_NO_DATA:
                return None
            raise PipeClosed(f"read error {err}")
        msg = self.buf.raw[:n.value].decode("utf-8", "replace")
        if msg == "garbage_collected":  # SirNukes' Lua sends this when it drops the pipe
            raise PipeClosed("game released the pipe")
        return msg

    def write(self, msg):
        """Queue one message for the game. Drops it if the pipe buffer is full."""
        data = msg.encode("utf-8")
        n = wintypes.DWORD(0)
        if not kernel32.WriteFile(self.handle, data, len(data), ctypes.byref(n), None):
            err = ctypes.get_last_error()
            raise PipeClosed(f"write error {err}")
        return n.value == len(data)

    def close(self):
        if self.handle is not None:
            kernel32.DisconnectNamedPipe(self.handle)
            kernel32.CloseHandle(self.handle)
        self.handle, self.connected = None, False


def parse_address(text, default_port):
    host, sep, port = text.rpartition(":")
    if not sep:
        host, port = text, ""
    return socket.gethostbyname(host), int(port) if port else default_port


def log(text):
    print(time.strftime("%H:%M:%S ") + text, flush=True)


def fmt_addr(addr):
    return f"{addr[0]}:{addr[1]}" if addr else None


def local_address(peer, port):
    """The address this PC sends to peer from: the interface's IP (a UDP connect sends nothing) and our port."""
    if peer:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(peer)
                return f"{s.getsockname()[0]}:{port}"
        except OSError:
            pass
    return f"0.0.0.0:{port}"


def this_machine():
    clean = lambda text: str(text).replace("|", "/")  # noqa: E731  (fields of the H keepalive)
    return {"host": clean(socket.gethostname()), "pid": os.getpid(), "os": clean(platform.platform(terse=True))}


def wire_header(data):
    """Our header of a datagram, readable without the password: magic, HMAC tag, session, counter, send time."""
    head = {"magic": data[:4].decode("ascii", "replace")}
    tag, _, rest = data[len(MAGIC):].partition(b" ")
    meta = rest.partition(b" ")[0]
    try:
        session, counter, stamp = meta.decode("ascii").split(":")
        head.update(tag=tag.decode("ascii"), session=session, counter=int(counter), sent=int(stamp))
    except (UnicodeDecodeError, ValueError):
        pass  # unencrypted (--no-password) or not ours
    return head


GAME_FIELDS = {  # field names of the game's messages (see ui/x4_coop.lua), for the trace tools
    "S": "seq t sector ship x y z yaw pitch roll vx vy vz name idcode hull shield",
    "D": "code macro sector hull enemy", "K": "code macro sector", "F": "code macro sector",
    "L": "world role ship protocol", "M": "name text", "P": "t", "Q": "t", "R": "role",
    "B": "t sector radius complete ships", "H": "host pid os t echo hold",
    "E": "what pass index count station wares trades", "C": "what id amount name", "T": "what id station ware change", "V": "what relations ids", "U": "what id kind item extra", "Z": "what active factor note", "O": "what id code macro sector owner", "Y": "what id code macro sector shipyard name wares", "G": "what id ship order clear args params", "J": "what id ship default queue", "I": "what station macro sector room index x y z speed name",
    "b": "what id station macro sector x y z yaw pitch roll module x y z yaw pitch roll equipment",
    "q": "what id ship macro sector equipment",
    "p": "what id op deployable macro sector x y z",
    "n": "what id kind name macro sector revealed",
    "l": "what id ship macro sector name",
    "w": "what id ship macro sector crew",
    "g": "what a b c d e f g h i j k l m n o p q",
    "h": "what id category title text credits",
    "d": "what id kind macro sector x y z station smacro",
    "f": "what id ship macro sector cargo",
    "t": "what id op cluster project",
    "s": "what id op station name fill buildprice supplyrule buildrule manager wares",
    "c": "what id ship macro sector commander cmacro csector group assignment",
    "r": "what id op rule name whitelist defaults factions",
    "a": "what id station change min max",
    "m": "what id op mission name description objective faction target macro sector x y z",
    "e": "what id change before station macro sector module x y z yaw pitch roll",
}


def decode_game(msg):
    """A message's fields by name, e.g. {"kind": "S", "x": "12.50", ...}. Only the trace tools look inside."""
    kind, _, rest = (msg or "").partition("|")
    names = GAME_FIELDS.get(kind, "").split()
    out = {"kind": kind}
    if names and rest:
        out.update(zip(names, rest.split("|", len(names) - 1)))
    return out


class Telemetry:
    """
    What this bridge saw, as proof and for debugging: its socket bindings, every datagram (addresses, our
    header, the bytes on the wire, the decrypted message and what became of it), the partner machine with the
    round-trip time, X4's pipe connection and the save transfer. One JSON object per line, to --trace FILE and/or
    live to the overlay window (--overlay). Stays on this PC; nothing here is sent to the partner.
    """

    def __init__(self, path=None, overlay=False, hex_bytes=TRACE_HEX_BYTES):
        self.path, self.hex_bytes = path, hex_bytes
        self.lock = threading.Lock()
        self.file = None
        self.feed = None
        self.last_flush = 0.0
        self.drops = (0.0, 0)  # (second started, datagrams recorded in it) for the TRACE_DROPS_PER_S limit
        if path:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            self.file = open(path, "a", encoding="utf-8")
        if overlay:
            here = os.path.dirname(os.path.abspath(__file__))
            with open(os.path.join(here, "x4_coop_overlay.log"), "a", encoding="utf-8") as errors:
                self.proc = subprocess.Popen([sys.executable, "-I", os.path.join(here, "x4_coop_overlay.py")],
                                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors,
                                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            self.feed = queue.Queue(maxsize=5000)
            threading.Thread(target=self._pump, daemon=True).start()

    @property
    def on(self):
        return self.file is not None or self.feed is not None

    def emit(self, ev, **fields):
        if not self.on:
            return
        line = json.dumps({"ev": ev, "wall": round(time.time(), 6), **fields}, separators=(",", ":")) + "\n"
        with self.lock:
            if self.file:
                self.file.write(line)
                if time.monotonic() - self.last_flush > 1.0:
                    self.last_flush = time.monotonic()
                    self.file.flush()
            feed = self.feed
        if feed is not None:
            try:
                feed.put_nowait(line)
            except queue.Full:
                pass  # the overlay is behind: skip lines rather than stall the relay

    def packet(self, direction, data, local, remote, limited=False, **fields):
        """One datagram. limited: a rejected/ignored one, recorded at most TRACE_DROPS_PER_S times a second."""
        if not self.on:
            return
        if limited:
            now = time.monotonic()
            start, count = self.drops if now - self.drops[0] < 1.0 else (now, 0)
            self.drops = (start, count + 1)
            if count >= TRACE_DROPS_PER_S:
                return
        shown = data if not self.hex_bytes else data[:self.hex_bytes]
        self.emit("pkt", dir=direction, local=local, remote=fmt_addr(remote), bytes=len(data),
                  udp_len=len(data) + 8, hdr=wire_header(data), hex=shown.hex(), **fields)

    def _pump(self):
        while True:
            line = self.feed.get()
            try:
                self.proc.stdin.write(line.encode("utf-8"))
                if self.feed.empty():
                    self.proc.stdin.flush()
            except OSError:  # the overlay window was closed
                self.feed = None
                log("overlay closed (the bridge keeps running)")
                return

    def close(self):
        with self.lock:
            if self.file:
                self.file.close()
                self.file = None


@functools.lru_cache(maxsize=8)
def derive_keys(password):
    """
    Password -> (signing key, encryption key, save key). scrypt makes every guess cost ~0.1 s and 32 MB, so
    someone who records a packet can't try passwords quickly; a long password (a few random words) still matters.
    """
    master = hashlib.scrypt(password.encode("utf-8"), salt=KDF_SALT, n=1 << 15, r=8, p=1, maxmem=64 << 20, dklen=32)
    return tuple(hmac.new(master, label, hashlib.sha256).digest() for label in (b"sign", b"encrypt", b"save"))


def keystream_xor(key, nonce, data):
    """Encrypts or decrypts: data XOR SHAKE-256(key + nonce). Each nonce is used once per key."""
    if not data:
        return b""
    stream = hashlib.shake_256(key + nonce).digest(len(data))
    return (int.from_bytes(data, "big") ^ int.from_bytes(stream, "big")).to_bytes(len(data), "big")


class Codec:
    """
    Frames one pipe message per datagram: MAGIC + message. With a password the message is encrypted and signed:
    MAGIC + tag + " " + session:counter:unixtime + " " + ciphertext. The ciphertext is the message XORed with a
    keystream from the encryption key and that header (session is random per bridge start, counter never repeats);
    tag is the first 32 hex digits of HMAC-SHA256 over header and ciphertext. A replayed datagram fails the counter
    check; an old one the time check.
    """

    MAX_SKEW_S = 60      # sender's clock may differ from ours by this much
    MAX_SESSIONS = 16    # remembered senders (each restart of a bridge is a new session)
    WINDOW = 256         # a datagram may arrive this many counters late (UDP reorders) and still count once

    def __init__(self, password=""):
        self.key, self.enc_key, self.save_key = derive_keys(password) if password else (None, None, None)
        self.session = os.urandom(8).hex()
        self.counter = 0
        self.seen = {}           # session -> (highest counter accepted, set of accepted counters in the window)
        self.last_reject = ""

    def _tag(self, data):
        return hmac.new(self.key, data, hashlib.sha256).hexdigest()[:32].encode()

    def seal(self, msg):
        data = msg.encode("utf-8")
        if self.key:
            self.counter += 1
            header = f"{self.session}:{self.counter}:{int(time.time())}".encode()
            data = header + b" " + keystream_xor(self.enc_key, header, data)
            data = self._tag(data) + b" " + data
        return MAGIC + data

    def open(self, datagram):
        """The message text, or None (see last_reject) for foreign, unsigned, replayed or stale traffic."""
        if not datagram.startswith(MAGIC):
            self.last_reject = ("your partner runs a different version of the bridge; update both"
                                if datagram.startswith(b"X4C") else "not ours")
            return None
        data = datagram[len(MAGIC):]
        if self.key:
            tag, sep, signed = data.partition(b" ")
            if not sep or not hmac.compare_digest(tag, self._tag(signed)):
                self.last_reject = "wrong or missing --password"
                return None
            meta, sep, data = signed.partition(b" ")
            try:
                session, counter, stamp = meta.decode().split(":")
                counter, stamp = int(counter), int(stamp)
            except ValueError:
                self.last_reject = "malformed"
                return None
            if abs(time.time() - stamp) > self.MAX_SKEW_S:
                self.last_reject = "too old, or the two PCs' clocks differ by over a minute"
                return None
            top, recent = self.seen.get(session, (0, set()))
            if counter <= top - self.WINDOW or counter in recent:
                self.last_reject = "replayed"
                return None
            if session not in self.seen and len(self.seen) >= self.MAX_SESSIONS:
                self.seen.pop(next(iter(self.seen)))
            recent.add(counter)
            top = max(top, counter)
            if len(recent) > 2 * self.WINDOW:
                recent = {c for c in recent if c > top - self.WINDOW}
            self.seen[session] = (top, recent)
            data = keystream_xor(self.enc_key, meta, data)
        return data.decode("utf-8", "replace")


class RateLimit:
    """Token bucket: allow() is False once more than `rate` per second (plus `burst`) arrive."""

    def __init__(self, rate, burst):
        self.rate, self.burst, self.tokens, self.at = rate, burst, burst, time.monotonic()

    def allow(self, now):
        self.tokens = min(self.burst, self.tokens + (now - self.at) * self.rate)
        self.at = now
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


MAX_SAVE_BYTES = 1 << 30   # refuse anything bigger than 1 GiB
SHARE_WAIT_S = 90          # host: how long to wait for the game to finish writing the save
OFFER_TTL_S = 120          # host: how long the partner has to fetch it
GZIP_MAGIC = b"\x1f\x8b"
SAVE_CHUNK = 1 << 20       # the save travels in 1 MB pieces, each encrypted with its own nonce


def gzip_complete(data):
    """True if data is a whole gzip stream: inflates to the end and the trailer's CRC and size match."""
    if not data.startswith(GZIP_MAGIC):
        return False
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        for i in range(0, len(data), 1 << 20):
            d.decompress(data[i:i + (1 << 20)], 1 << 16)
            while d.unconsumed_tail:
                d.decompress(d.unconsumed_tail, 1 << 16)
    except zlib.error:
        return False
    return d.eof


class SaveShare:
    """
    Hands the host's save to the joiner's bridge (the shared world starts from the host's save).

    Host: the game quicksaves and sends "X|share|<save folder>|quicksave.xml.gz". Once the file has been
    rewritten and stopped growing, it is offered over the signed UDP link ("X|offer|size|sha256|token") and
    served once over TCP on the same port number, only to the partner's address, only after an HMAC proof
    of the shared password over the one-time token, encrypted with the save key and that token.
    Joiner: the game reports its save folder ("X|savedir|<path>"). On an offer, the bridge fetches the file,
    checks size, sha256 and gzip header, keeps a backup of the quicksave it replaces, and tells the game
    ("X|received|quicksave"). Transfers run on threads; results come back through a queue, so the relay
    loop never stalls.
    """

    def __init__(self, codec, port, role, tele=None):
        self.codec, self.port, self.role = codec, port, role
        self.tele = tele or Telemetry()
        self.save_dir = None
        self.pending = None
        self.offer = None
        self.events = queue.Queue()  # ("game", message) or ("log", text)
        self.prepared = queue.Queue()  # host: (path, data or None) from the checking thread
        self.checking = False
        self.fetching = threading.Lock()

    def _proof(self, token):
        return hmac.new(self.codec.key, b"fetch:" + token.encode(), hashlib.sha256).hexdigest().encode()

    def _crypt(self, token, offset, chunk):
        """Encrypts or decrypts the save's bytes at offset (a multiple of SAVE_CHUNK)."""
        return keystream_xor(self.codec.save_key, f"{token}:{offset}".encode(), chunk)

    def _say(self, text):
        self.events.put(("game", "N|" + text))
        self.events.put(("log", text))

    # --- the joiner's own wallet and inventory, kept next to the saves between sessions
    PROFILE_KEY = re.compile(r"^[0-9a-z]{1,32}$")
    PROFILE_CREDITS = re.compile(r"^-?\d{1,15}$")
    PROFILE_WARES = re.compile(r"^[\w=,]{0,8000}$")

    def _profile_path(self, key):
        if not (self.save_dir and self.PROFILE_KEY.match(key)):
            return None
        return os.path.join(self.save_dir, "x4coop_profile_%s.txt" % key)

    def _profile_put(self, key, credits, wares):
        path = self._profile_path(key)
        if not path or not self.PROFILE_CREDITS.match(credits) or not self.PROFILE_WARES.match(wares):
            return
        try:
            with open(path + ".tmp", "w", encoding="utf-8") as fh:
                fh.write(credits + "\n" + wares + "\n")
            os.replace(path + ".tmp", path)
        except OSError as e:
            self.events.put(("log", "can't keep the joiner's wallet in %s: %s" % (path, e)))

    def _profile_get(self, key):
        path, reply = self._profile_path(key), "X|profile|%s|none" % key
        if path and os.path.isfile(path):
            try:
                lines = open(path, encoding="utf-8").read().split("\n")
                if len(lines) >= 2 and self.PROFILE_CREDITS.match(lines[0]) and self.PROFILE_WARES.match(lines[1]):
                    reply = "X|profile|%s|%s|%s" % (key, lines[0], lines[1])
            except OSError:
                pass
        if self.PROFILE_KEY.match(key):
            self.events.put(("game", reply))

    # --- messages from our own game
    def from_game(self, f):
        if f[1] == "savedir" and len(f) >= 3 and os.path.isdir(f[2]):
            self.save_dir = f[2]
        elif f[1] == "profile_put" and len(f) >= 5:
            self._profile_put(f[2], f[3], f[4])
        elif f[1] == "profile_get" and len(f) >= 3:
            self._profile_get(f[2])
        elif f[1] == "share" and len(f) >= 4:
            name = os.path.basename(f[3])
            if not self.codec.key:
                self._say("sharing a save needs a password on both bridges")
            elif not name.lower().endswith(".xml.gz") or not os.path.isdir(f[2]):
                self._say("can't share that save")
            else:
                self.pending = {"path": os.path.join(f[2], name), "asked": time.time(), "size": -1, "since": 0.0}

    # --- host side, every loop
    def tick(self, partner, send_udp):
        p, now = self.pending, time.time()
        if p:
            try:
                st = os.stat(p["path"])
            except OSError:
                st = None
            if now - p["asked"] > SHARE_WAIT_S:
                self.pending = None
                self._say("the save to share did not appear; try /x4coop share again")
            elif st and st.st_mtime >= p["asked"] - 1 and not self.checking:
                if st.st_size != p["size"]:
                    p["size"], p["since"] = st.st_size, now
                elif now - p["since"] >= 1.5:  # stopped growing: is it really complete?
                    self.checking = True
                    threading.Thread(target=self._check, args=(p["path"],), daemon=True).start()
        while not self.prepared.empty():
            path, data = self.prepared.get()
            self.checking = False
            if self.pending and data is not None:
                self.pending = None
                self._offer(data, partner, send_udp)
            elif self.pending:
                self.pending["since"] = now  # not complete yet: look again in a moment
        o = self.offer
        if o:
            if now > o["deadline"]:
                self._close_offer()
                self._say("your partner did not fetch the save in time")
                return
            try:
                conn, addr = o["listener"].accept()
            except (BlockingIOError, OSError):
                return
            allowed = bool(partner) and addr[0] == partner[0]
            self.tele.emit("tcp", what="accept", local=f"0.0.0.0:{self.port}", remote=fmt_addr(addr), allowed=allowed)
            if not allowed:
                conn.close()
                return
            self._close_offer()
            threading.Thread(target=self._serve, args=(conn, o), daemon=True).start()

    def _check(self, path):
        try:
            with open(path, "rb") as fh:
                data = fh.read(MAX_SAVE_BYTES + 1)
        except OSError:
            data = b""
        ok = len(data) <= MAX_SAVE_BYTES and gzip_complete(data)
        self.prepared.put((path, data if ok else None))

    def _offer(self, data, partner, send_udp):
        if not partner:
            self._say("no partner to send the save to")
            return
        self._close_offer()  # a new share replaces an unfetched one
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            listener.bind(("0.0.0.0", self.port))
            listener.listen(1)
            listener.setblocking(False)
        except OSError as e:
            listener.close()
            self._say(f"can't open TCP port {self.port} for the save: {e}")
            return
        token = os.urandom(16).hex()
        self.offer = {"data": data, "token": token, "listener": listener, "deadline": time.time() + OFFER_TTL_S}
        sha = hashlib.sha256(data).hexdigest()
        self.tele.emit("tcp", what="listen", local=f"0.0.0.0:{self.port}", bytes=len(data), sha256=sha)
        send_udp(f"X|offer|{len(data)}|{sha}|{token}", "bridge")
        self._say(f"offering your save ({len(data) / 1e6:.1f} MB) to your partner")

    def _close_offer(self):
        if self.offer:
            self.offer["listener"].close()
            self.offer = None

    def _serve(self, conn, offer):
        started = time.monotonic()
        try:
            remote = fmt_addr(conn.getpeername())
            conn.settimeout(30)
            line = b""
            while not line.endswith(b"\n") and len(line) < 200:
                chunk = conn.recv(200 - len(line))
                if not chunk:
                    break
                line += chunk
            if not hmac.compare_digest(line.strip(), self._proof(offer["token"])):
                self.events.put(("log", "save fetch refused: wrong proof"))
                self.tele.emit("tcp", what="refused", remote=remote, reason="wrong proof")
                return
            view = memoryview(offer["data"])
            first = b""
            for i in range(0, len(view), SAVE_CHUNK):  # the 30 s timeout applies per 1 MB chunk
                chunk = self._crypt(offer["token"], i, view[i:i + SAVE_CHUNK])
                first = first or chunk[:32]
                conn.sendall(chunk)
            self.tele.emit("tcp", what="sent", local=fmt_addr(conn.getsockname()), remote=remote,
                           bytes=len(view), seconds=round(time.monotonic() - started, 3), hex=first.hex())
            self._say(f"save sent to your partner ({len(offer['data']) / 1e6:.1f} MB)")
        except OSError as e:
            self._say(f"sending the save failed: {e}")
        finally:
            conn.close()

    # --- joiner side
    def on_offer(self, f, host):
        try:
            size, sha, token = int(f[2]), f[3], f[4]
        except (IndexError, ValueError):
            return
        if not (0 < size <= MAX_SAVE_BYTES and len(sha) == 64 and len(token) == 32) or self.role != "join":
            return
        if not self.codec.key:
            self._say("the host offered a save, but receiving one needs a password on both bridges")
        elif not self.save_dir:
            self._say("the host offered a save, but this bridge doesn't know your save folder yet (is X4 connected?)")
        elif not self.fetching.acquire(blocking=False):
            self._say("still fetching the previous save from the host")
        else:
            threading.Thread(target=self._fetch, args=(host, size, sha, token, self.save_dir), daemon=True).start()

    def _fetch(self, host, size, sha, token, save_dir):
        started = time.monotonic()
        try:
            with socket.create_connection(host, timeout=15) as conn:
                self.tele.emit("tcp", what="connect", local=fmt_addr(conn.getsockname()), remote=fmt_addr(host))
                conn.settimeout(60)
                conn.sendall(self._proof(token) + b"\n")
                chunks, got = [], 0
                while got < size:
                    chunk = conn.recv(min(1 << 20, size - got))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    got += len(chunk)
            data = b"".join(chunks)
            wire = data[:32].hex()
            data = b"".join(self._crypt(token, i, data[i:i + SAVE_CHUNK]) for i in range(0, len(data), SAVE_CHUNK))
            intact = len(data) == size and hashlib.sha256(data).hexdigest() == sha and gzip_complete(data)
            self.tele.emit("tcp", what="received", remote=fmt_addr(host), bytes=len(data), sha256_ok=intact,
                           seconds=round(time.monotonic() - started, 3), hex=wire)
            if not intact:
                self._say("the host's save arrived damaged; ask them to /x4coop share again")
                return
            target = os.path.join(save_dir, "quicksave.xml.gz")
            note = ""
            if os.path.exists(target):
                backup = target + time.strftime(".bak-%Y%m%d-%H%M%S")
                os.replace(target, backup)
                note = f"; your old quicksave is kept as {os.path.basename(backup)}"
            with open(target + ".part", "wb") as fh:
                fh.write(data)
            os.replace(target + ".part", target)
            self._say(f"host's save received ({size / 1e6:.1f} MB){note}")
            self.events.put(("game", "X|received|quicksave"))
        except OSError as e:
            self._say(f"fetching the host's save failed: {e}")
        finally:
            self.fetching.release()


def trace_path(choice, me, role):
    """--trace FILE, or with no FILE: bridge/traces/x4coop-<machine>-<role>-<date-time>.jsonl."""
    if choice != "auto":
        return choice
    folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "traces")
    name = "".join(c if c.isalnum() or c in "-_" else "_" for c in me["host"])
    return os.path.join(folder, f"x4coop-{name}-{role}-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")


def run(args):
    if args.join:
        peer, port = parse_address(args.join, DEFAULT_PORT), args.port or 0
    elif args.peer:
        peer, port = parse_address(args.peer, DEFAULT_PORT), args.port or DEFAULT_PORT
    else:
        peer, port = None, args.port or DEFAULT_PORT
    hosting = peer is None  # host mode: adopt the first partner that talks to us
    role = args.role or ("host" if hosting else "join")  # told to the game: the host's save is the shared world
    codec = Codec(args.password)
    limit = RateLimit(MAX_PACKETS_PER_S, MAX_PACKETS_PER_S * 2)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)  # ignore ICMP "port unreachable" from an absent partner
    sock.bind(("0.0.0.0", port))
    sock.setblocking(False)
    port = sock.getsockname()[1]
    me = this_machine()
    tele = Telemetry(trace_path(args.trace, me, role), args.overlay, args.trace_bytes)
    share = SaveShare(codec, port, role, tele)

    game = GamePipe(args.pipe)
    local = local_address(peer, port)
    log(f"UDP port {port}; " + (f"partner {peer[0]}:{peer[1]}" if peer else "waiting for a partner to join")
        + ("; encrypted with your password" if args.password else ""))
    if args.password and len(args.password) < SHORT_PASSWORD:
        log(f"note: short password. Fine on a LAN or Tailscale; over the open internet use {SHORT_PASSWORD}+ "
            "characters (a few random words), because anyone who records a packet can try guesses offline")
    if tele.path:
        log(f"recording a telemetry trace to {tele.path}")
    log(f"waiting for X4 on {game.path}")
    tele.emit("start", machine=me, role=role, udp_bind=f"0.0.0.0:{port}", local=local, peer=fmt_addr(peer),
              pipe=game.path, encrypted=bool(args.password), wire=MAGIC.decode().strip(),
              python=platform.python_version(), trace=tele.path)

    stats = {"to_peer": 0, "from_peer": 0, "to_game": 0, "dropped": 0, "rejected": 0, "ignored": 0, "flooded": 0}
    last_heard = 0.0
    partner_present = False
    partner_clock = None  # (partner's clock in its last keepalive, our clock when it arrived), both ms
    last_keepalive = 0.0
    last_stats = time.monotonic()
    last_reject_note = 0.0

    def send(msg, src="game"):
        data = codec.seal(msg)
        try:
            sock.sendto(data, peer)
        except OSError as e:  # e.g. network unreachable; the keepalive retries every second
            log(f"send failed: {e}")
            tele.emit("send_failed", remote=fmt_addr(peer), error=str(e))
            return False
        tele.packet("tx", data, local, peer, src=src, msg=msg)
        return True

    def hello():
        """Keepalive H: names this machine and carries clocks, so each side measures the round trip."""
        t = int(time.monotonic() * 1000)
        echo, hold = (partner_clock[0], t - partner_clock[1]) if partner_clock else (0, 0)
        return f"H|{me['host']}|{me['pid']}|{me['os']}|{t}|{echo}|{hold}"

    def game_lost(e):
        log(f"X4 disconnected ({e}); waiting for it to reconnect")
        tele.emit("pipe", state="disconnected", reason=str(e))
        game.close()

    def tell_game(msg):
        if not game.connected:
            return
        try:
            if game.write(msg):
                stats["to_game"] += 1
            else:
                stats["dropped"] += 1
        except PipeClosed as e:
            game_lost(e)

    while True:
        busy = False
        now = time.monotonic()

        if not game.connected:
            if game.poll_connect():
                pid, exe = game.client()
                if not args.any_client and (not exe or os.path.basename(exe).lower() != "x4.exe"):
                    log(f"rejected pipe client {exe or '?'} (pid {pid}): only X4.exe may connect (--any-client to allow)")
                    tele.emit("pipe", state="rejected", pid=pid, exe=exe)
                    game.close()
                    time.sleep(0.2)
                    continue
                log(f"X4 connected (pid {pid})")
                tele.emit("pipe", state="connected", pid=pid, exe=exe, path=game.path)
                where = f"partner {peer[0]}:{peer[1]}" if peer else f"UDP {port}, waiting for a partner"
                tell_game(f"W|bridge ready ({where})")
                tell_game(f"R|{role}")
                if partner_present:
                    tell_game("N|partner connected")
        else:
            try:
                while True:
                    msg = game.read()
                    if msg is None:
                        break
                    busy = True
                    if msg.startswith("X|"):
                        share.from_game(msg.split("|"))
                    elif peer and send(msg):
                        stats["to_peer"] += 1
            except PipeClosed as e:
                game_lost(e)

        while True:
            try:
                data, addr = sock.recvfrom(65535)
            except (BlockingIOError, ConnectionResetError):
                break
            busy = True
            msg = codec.open(data)
            if msg is None:
                if data.startswith(b"X4C"):  # ours, any version
                    stats["rejected"] += 1
                    tele.packet("rx", data, local, addr, limited=True, verdict="rejected: " + codec.last_reject)
                    if now - last_reject_note > 10:
                        last_reject_note = now
                        log(f"rejected packets from {addr[0]}:{addr[1]}: {codec.last_reject}")
                continue
            # One partner at a time: a host keeps its partner's exact address until they go silent;
            # a joiner only listens to its host's IP (its NAT may change the port).
            foreign = (addr != peer) if hosting else (addr[0] != peer[0])
            if peer and foreign and (partner_present or not hosting):
                stats["ignored"] += 1
                tele.packet("rx", data, local, addr, limited=True, msg=msg, verdict="ignored: not your partner")
                continue
            if not limit.allow(now):
                stats["flooded"] += 1
                tele.packet("rx", data, local, addr, limited=True, verdict="dropped: too many packets")
                continue
            last_heard = now
            if hosting and addr != peer:
                peer = addr
                local = local_address(peer, port)
                log(f"partner is {addr[0]}:{addr[1]}")
            if not partner_present:
                partner_present = True
                log("partner connected")
                tele.emit("link", state="connected", local=local, remote=fmt_addr(addr))
                tell_game("N|partner connected")
            if msg == "H" or msg.startswith("H|"):
                h = decode_game(msg)
                try:
                    partner_clock = (int(h["t"]), int(now * 1000))
                    echo, hold = int(h["echo"]), int(h["hold"])
                    rtt = int(now * 1000) - echo - hold if echo else None
                    tele.emit("peer", machine={"host": h["host"], "pid": h["pid"], "os": h["os"]},
                              remote=fmt_addr(addr), rtt_ms=rtt if rtt is not None and 0 <= rtt < 10000 else None)
                except (KeyError, ValueError):
                    pass  # a plain "H" from an older bridge
                tele.packet("rx", data, local, addr, msg=msg, verdict="keepalive")
                continue
            if msg.startswith("X|offer|") and role == "join":
                tele.packet("rx", data, local, addr, msg=msg, verdict="save offer")
                share.on_offer(msg.split("|"), peer)
                continue
            if msg[:1] not in FROM_PARTNER or msg[1:2] != "|":
                stats["ignored"] += 1
                tele.packet("rx", data, local, addr, msg=msg, verdict="ignored: not a partner message")
                continue
            stats["from_peer"] += 1
            tele.packet("rx", data, local, addr, msg=msg, verdict="to X4" if game.connected else "X4 not connected")
            tell_game(msg)

        share.tick(peer if partner_present else None, send)
        while not share.events.empty():
            kind, text = share.events.get()
            if kind == "game":
                tell_game(text)
            else:
                log(text)
        if partner_present and now - last_heard > PARTNER_TIMEOUT_S:
            partner_present = False
            log("partner silent")
            tele.emit("link", state="silent", remote=fmt_addr(peer))
            tell_game("N|partner silent")
        if peer and now - last_keepalive > KEEPALIVE_S:
            last_keepalive = now
            send(hello(), "bridge")  # keeps NAT mappings open and lets a host find us
        if now - last_stats > STATS_EVERY_S:
            last_stats = now
            log("stats: " + ", ".join(f"{k} {v}" for k, v in stats.items()))
            tele.emit("stats", **stats)
        if not busy:
            time.sleep(0.002)


def main(argv=None):
    p = argparse.ArgumentParser(description="X4 Co-op network bridge")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--host", action="store_true", help="wait for a partner to join (default)")
    mode.add_argument("--join", metavar="ADDR[:PORT]", help="connect to a hosting partner")
    mode.add_argument("--peer", metavar="ADDR[:PORT]",
                      help="fixed partner address; both sides use it. Over the internet this often works without "
                           "port forwarding, since both sides send first and open their own routers")
    p.add_argument("--port", type=int, default=None, help=f"local UDP port (default {DEFAULT_PORT}; random when joining)")
    p.add_argument("--pipe", default="x4_coop", help="pipe name, must match config.pipe in ui/x4_coop.lua")
    p.add_argument("--password", default=os.environ.get("X4COOP_PASSWORD", ""),
                   help="shared secret; both bridges must use the same one (or set X4COOP_PASSWORD)")
    p.add_argument("--no-password", action="store_true",
                   help="run without a password: nothing is encrypted, and anyone who can reach this port can "
                        "act as your partner")
    p.add_argument("--any-client", action="store_true",
                   help="let any local program use the pipe, not only X4.exe (for test tools)")
    p.add_argument("--role", choices=["host", "join"],
                   help="whose save is the shared world (default: --host is host, --join is join; required with --peer)")
    p.add_argument("--trace", nargs="?", const="auto", metavar="FILE",
                   help="record telemetry (bindings, every datagram, partner machine, save transfer) as JSON lines; "
                        "without FILE: bridge/traces/x4coop-<machine>-<role>-<time>.jsonl. Compare two machines' "
                        "traces with x4_coop_trace_report.py")
    p.add_argument("--trace-bytes", type=int, default=TRACE_HEX_BYTES, metavar="N",
                   help=f"bytes of each datagram recorded in hex (default {TRACE_HEX_BYTES}; 0 = whole datagram)")
    p.add_argument("--overlay", action="store_true",
                   help="show the live telemetry window on top of the game (X4 in borderless or windowed mode)")
    args = p.parse_args(argv)
    if args.peer and not args.role:
        p.error("--peer needs --role host or --role join (exactly one side hosts the shared world)")
    if not args.password and not args.no_password:
        p.error("set --password (both players use the same one), or --no-password to accept anyone who can reach you")
    try:
        run(args)
    except KeyboardInterrupt:
        log("stopped")
    except OSError as e:
        log(f"error: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
