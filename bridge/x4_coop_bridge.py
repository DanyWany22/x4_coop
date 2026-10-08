#!/usr/bin/env python3
"""
X4 Co-op network bridge:  X4 <-> named pipe <-> UDP <-> your partner's bridge <-> their X4.

Each player runs one bridge on the same PC as their game (start it before or after X4;
it waits for the game and reconnects after reloads):

    python x4_coop_bridge.py --host                   # wait for a partner on UDP 47810
    python x4_coop_bridge.py --join 203.0.113.7       # connect to a host (port defaults to 47810)
    python x4_coop_bridge.py --peer 100.64.0.2:47810  # both name each other (LAN / VPN)

Only the host needs to be reachable (UDP port forwarded, or both on a VPN such as
Tailscale/ZeroTier). Add the same --password on both sides to ignore anyone else's packets.
Standard library only: Windows, Python 3.8+.

X4 reaches this pipe through SirNukes' Mod Support APIs (Protected UI Mode must be off).
Datagrams are b"X4C1 " [+ HMAC tag] + one pipe message (see Codec); the message format is
documented in ui/x4_coop.lua. "H" keepalives are handled here and never reach the game.
A host serves one partner at a time and takes a new one only after the current one goes silent.
"""
import argparse
import ctypes
import hashlib
import hmac
import os
import socket
import sys
import time
from ctypes import wintypes

MAGIC = b"X4C1 "
DEFAULT_PORT = 47810
BUFFER_SIZE = 64 * 1024
KEEPALIVE_S = 1.0
PARTNER_TIMEOUT_S = 10.0
STATS_EVERY_S = 30.0
MAX_PACKETS_PER_S = 200  # a partner sends ~22/s; anything far above that is dropped

# Win32 named pipe API through ctypes, mirroring the parameters SirNukes' own server uses.
PIPE_ACCESS_DUPLEX = 0x3
PIPE_TYPE_MESSAGE = 0x4
PIPE_READMODE_MESSAGE = 0x2
PIPE_NOWAIT = 0x1
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
        h = kernel32.CreateNamedPipeW(self.path, PIPE_ACCESS_DUPLEX,
                                      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT,
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


class Codec:
    """Frames one pipe message per datagram: MAGIC, then (with a password) a 16-hex HMAC tag and a space."""

    def __init__(self, password=""):
        self.key = hashlib.sha256(password.encode("utf-8")).digest() if password else None

    def _tag(self, data):
        return hmac.new(self.key, data, hashlib.sha256).hexdigest()[:16].encode()

    def seal(self, msg):
        data = msg.encode("utf-8")
        if self.key:
            data = self._tag(data) + b" " + data
        return MAGIC + data

    def open(self, datagram):
        """The message text, or None for foreign traffic or a wrong/missing password."""
        if not datagram.startswith(MAGIC):
            return None
        data = datagram[len(MAGIC):]
        if self.key:
            tag, sep, data = data.partition(b" ")
            if not sep or not hmac.compare_digest(tag, self._tag(data)):
                return None
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


def run(args):
    if args.join:
        peer, port = parse_address(args.join, DEFAULT_PORT), args.port or 0
    elif args.peer:
        peer, port = parse_address(args.peer, DEFAULT_PORT), args.port or DEFAULT_PORT
    else:
        peer, port = None, args.port or DEFAULT_PORT
    hosting = peer is None  # host mode: adopt the first partner that talks to us
    codec = Codec(args.password)
    limit = RateLimit(MAX_PACKETS_PER_S, MAX_PACKETS_PER_S * 2)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)  # ignore ICMP "port unreachable" from an absent partner
    sock.bind(("0.0.0.0", port))
    sock.setblocking(False)
    port = sock.getsockname()[1]

    game = GamePipe(args.pipe)
    log(f"UDP port {port}; " + (f"partner {peer[0]}:{peer[1]}" if peer else "waiting for a partner to join")
        + ("; password required" if args.password else ""))
    log(f"waiting for X4 on {game.path}")

    stats = {"to_peer": 0, "from_peer": 0, "to_game": 0, "dropped": 0, "rejected": 0, "ignored": 0, "flooded": 0}
    last_heard = 0.0
    partner_present = False
    last_keepalive = 0.0
    last_stats = time.monotonic()
    last_reject_note = 0.0

    def send(msg):
        try:
            sock.sendto(codec.seal(msg), peer)
            return True
        except OSError as e:  # e.g. network unreachable; the keepalive retries every second
            log(f"send failed: {e}")
            return False

    def tell_game(msg):
        if not game.connected:
            return
        try:
            if game.write(msg):
                stats["to_game"] += 1
            else:
                stats["dropped"] += 1
        except PipeClosed as e:
            log(f"X4 disconnected ({e}); waiting for it to reconnect")
            game.close()

    while True:
        busy = False
        now = time.monotonic()

        if not game.connected:
            if game.poll_connect():
                log("X4 connected")
                where = f"partner {peer[0]}:{peer[1]}" if peer else f"UDP {port}, waiting for a partner"
                tell_game(f"W|bridge ready ({where})")
                if partner_present:
                    tell_game("N|partner connected")
        else:
            try:
                while True:
                    msg = game.read()
                    if msg is None:
                        break
                    busy = True
                    if peer and send(msg):
                        stats["to_peer"] += 1
            except PipeClosed as e:
                log(f"X4 disconnected ({e}); waiting for it to reconnect")
                game.close()

        while True:
            try:
                data, addr = sock.recvfrom(65535)
            except (BlockingIOError, ConnectionResetError):
                break
            busy = True
            msg = codec.open(data)
            if msg is None:
                if data.startswith(MAGIC):
                    stats["rejected"] += 1
                    if now - last_reject_note > 10:
                        last_reject_note = now
                        log(f"rejected packets from {addr[0]}:{addr[1]}: wrong or missing --password?")
                continue
            # One partner at a time: a host keeps its partner's exact address until they go silent;
            # a joiner only listens to its host's IP (its NAT may change the port).
            foreign = (addr != peer) if hosting else (addr[0] != peer[0])
            if peer and foreign and (partner_present or not hosting):
                stats["ignored"] += 1
                continue
            if not limit.allow(now):
                stats["flooded"] += 1
                continue
            last_heard = now
            if hosting and addr != peer:
                peer = addr
                log(f"partner is {addr[0]}:{addr[1]}")
            if not partner_present:
                partner_present = True
                log("partner connected")
                tell_game("N|partner connected")
            if msg == "H":
                continue
            stats["from_peer"] += 1
            tell_game(msg)

        if partner_present and now - last_heard > PARTNER_TIMEOUT_S:
            partner_present = False
            log("partner silent")
            tell_game("N|partner silent")
        if peer and now - last_keepalive > KEEPALIVE_S:
            last_keepalive = now
            send("H")  # keeps NAT mappings open and lets a host find us
        if now - last_stats > STATS_EVERY_S:
            last_stats = now
            log("stats: " + ", ".join(f"{k} {v}" for k, v in stats.items()))
        if not busy:
            time.sleep(0.002)


def main(argv=None):
    p = argparse.ArgumentParser(description="X4 Co-op network bridge")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--host", action="store_true", help="wait for a partner to join (default)")
    mode.add_argument("--join", metavar="ADDR[:PORT]", help="connect to a hosting partner")
    mode.add_argument("--peer", metavar="ADDR[:PORT]", help="fixed partner address; both sides use it")
    p.add_argument("--port", type=int, default=None, help=f"local UDP port (default {DEFAULT_PORT}; random when joining)")
    p.add_argument("--pipe", default="x4_coop", help="pipe name, must match config.pipe in ui/x4_coop.lua")
    p.add_argument("--password", default=os.environ.get("X4COOP_PASSWORD", ""),
                   help="shared secret; both bridges must use the same one (or set X4COOP_PASSWORD)")
    args = p.parse_args(argv)
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
