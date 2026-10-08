#!/usr/bin/env python3
"""
X4 Co-op telemetry overlay: a small always-on-top window over the game showing, live, what this PC's bridge
sends and receives: socket bindings, both machines, round trip, packet rates, both ships' state with each
machine's own game clock, hits and kills, and the latest datagrams' bytes on the wire.

Started by the bridge (--overlay), which feeds it the telemetry as JSON lines on stdin; or on its own with
--follow TRACE.jsonl to watch a trace a bridge is recording (--trace). X4 must run borderless or windowed:
an exclusive-fullscreen game covers every other window.

    Ctrl+Shift+F12   move mode: drag the window with the mouse, right-click to close it; press again to
                     lock it (locked, clicks pass through to the game)
    Ctrl+Shift+F11   hide / show
When the bridge stops, the overlay says so and closes a few seconds later.
"""
import argparse
import collections
import ctypes
import json
import math
import os
import queue
import sys
import threading
import time
import tkinter as tk
from ctypes import wintypes

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from x4_coop_bridge import decode_game  # noqa: E402  (the same field names the bridge documents)

SETTINGS = os.path.join(HERE, "x4_coop_overlay.json")
REFRESH_MS = 100
CLOSE_AFTER_BRIDGE_S = 5
RATE_WINDOW_S = 2.0
COLOURS = {"bg": "#0b0f14", "text": "#c9d1d9", "dim": "#6e7681", "head": "#e6edf3", "tx": "#3fb950",
           "rx": "#58a6ff", "warn": "#d29922", "bad": "#f85149", "move": "#d29922"}

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetAncestor.restype = wintypes.HWND
user32.GetAncestor.argtypes = [wintypes.HWND, ctypes.c_uint]
user32.GetWindowLongW.restype = ctypes.c_long
user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
user32.SetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_long]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_uint]
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
GWL_EXSTYLE = -20
WS_EX_LAYERED, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE = 0x80000, 0x20, 0x80, 0x08000000
HWND_TOPMOST = wintypes.HWND(-1)
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE = 0x1, 0x2, 0x10
VK_SHIFT, VK_CONTROL, VK_F11, VK_F12 = 0x10, 0x11, 0x7A, 0x7B


def clock(wall):
    return time.strftime("%H:%M:%S", time.localtime(wall)) + f".{int(wall % 1 * 1000):03d}"


def num(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def short(text, width):
    text = str(text or "")
    return text if len(text) <= width else text[:width - 1] + "…"


class Link:
    """Everything the overlay shows, built from the telemetry events."""

    def __init__(self):
        self.me = {}
        self.partner = {}
        self.partner_from = None
        self.rtts = collections.deque(maxlen=30)
        self.link = ("waiting", None)
        self.x4 = None
        self.rates = collections.deque()          # (wall, dir, bytes)
        self.totals = {"tx": 0, "rx": 0, "dropped": 0}
        self.ship = {"tx": None, "rx": None}      # latest S of this PC (sent) and of the partner (received)
        self.combat = collections.deque(maxlen=5)
        self.wire = collections.deque(maxlen=5)
        self.tcp = None
        self.error = None
        self.last_event = 0.0

    def take(self, ev):
        kind, wall = ev.get("ev"), ev.get("wall", time.time())
        self.last_event = wall
        if kind == "start":
            self.__init__()
            self.me, self.last_event = ev, wall
        elif kind == "pipe":
            self.x4 = ev if ev.get("state") == "connected" else None
        elif kind == "link":
            self.link = (ev.get("state"), wall)
        elif kind == "peer":
            self.partner, self.partner_from = ev.get("machine", {}), ev.get("remote")
            if ev.get("rtt_ms") is not None:
                self.rtts.append(ev["rtt_ms"])
        elif kind == "tcp":
            self.tcp = (wall, ev)
        elif kind == "send_failed":
            self.error = (wall, "send failed: " + str(ev.get("error")))
        elif kind == "pkt":
            self.packet(ev, wall)

    def packet(self, ev, wall):
        d, verdict = ev.get("dir"), ev.get("verdict") or ""
        if d == "tx" and ev.get("local"):
            self.me["local"] = ev["local"]  # a host learns which address it sends from once a partner talks
        if verdict.startswith(("rejected", "ignored: not your", "dropped")):
            self.totals["dropped"] += 1
            self.error = (wall, f"{verdict} from {ev.get('remote')}")
            return
        self.totals[d] = self.totals.get(d, 0) + 1
        self.rates.append((wall, d, ev.get("udp_len", 0)))
        g = decode_game(ev.get("msg"))
        self.wire.append((wall, d, ev, g["kind"]))
        if g["kind"] == "S":
            self.ship[d] = (wall, g)
        elif g["kind"] in ("D", "K", "F", "M"):
            self.combat.append((wall, d, g))

    def rate(self, d, now):
        while self.rates and now - self.rates[0][0] > RATE_WINDOW_S:
            self.rates.popleft()
        mine = [b for (_, k, b) in self.rates if k == d]
        return len(mine) / RATE_WINDOW_S, sum(mine) / RATE_WINDOW_S / 1024


class Overlay:
    def __init__(self, source, exit_after=None):
        self.source, self.link = source, Link()
        self.settings = {"x": 16, "y": 220, "alpha": 0.86}
        try:
            with open(SETTINGS, encoding="utf-8") as fh:
                self.settings.update(json.load(fh))
        except (OSError, ValueError):
            pass
        self.moving, self.hidden, self.keys = False, False, set()
        self.closed = False
        root = self.root = tk.Tk()
        root.title("X4 Co-op telemetry")
        root.overrideredirect(True)
        root.attributes("-topmost", True)
        root.attributes("-alpha", self.settings["alpha"])
        root.configure(bg=COLOURS["bg"])
        root.geometry(f"+{self.settings['x']}+{self.settings['y']}")
        self.text = tk.Text(root, width=72, height=25, bg=COLOURS["bg"], fg=COLOURS["text"], bd=0,
                            highlightthickness=2, highlightbackground=COLOURS["bg"], font=("Consolas", 9),
                            padx=8, pady=6, cursor="arrow", wrap="none")
        self.text.pack()
        for name, colour in COLOURS.items():
            self.text.tag_configure(name, foreground=colour)
        self.text.tag_configure("head", foreground=COLOURS["head"], font=("Consolas", 9, "bold"))
        for widget in (root, self.text):
            widget.bind("<ButtonPress-1>", self.drag_start)
            widget.bind("<B1-Motion>", self.drag)
            widget.bind("<ButtonPress-3>", lambda e: self.moving and self.quit())
        root.update_idletasks()
        self.hwnd = user32.GetAncestor(self.text.winfo_id(), 2)  # GA_ROOT: the top-level window
        self.click_through(True)
        if exit_after:
            root.after(int(exit_after * 1000), self.quit)
        root.after(REFRESH_MS, self.tick)

    # --- window behaviour
    def click_through(self, on):
        style = user32.GetWindowLongW(self.hwnd, GWL_EXSTYLE) | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        style = style | WS_EX_TRANSPARENT if on else style & ~WS_EX_TRANSPARENT
        user32.SetWindowLongW(self.hwnd, GWL_EXSTYLE, style)
        self.text.configure(highlightbackground=COLOURS["bg"] if on else COLOURS["move"])

    def drag_start(self, e):
        self.grab = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y())

    def drag(self, e):
        if self.moving:
            self.root.geometry(f"+{e.x_root - self.grab[0]}+{e.y_root - self.grab[1]}")

    def hotkeys(self):
        down = lambda vk: user32.GetAsyncKeyState(vk) & 0x8000  # noqa: E731
        combo = down(VK_CONTROL) and down(VK_SHIFT)
        for vk in (VK_F11, VK_F12):
            pressed = combo and down(vk)
            if pressed and vk not in self.keys:
                if vk == VK_F12:
                    self.moving = not self.moving
                    self.click_through(not self.moving)
                    if not self.moving:
                        self.save()
                else:
                    self.hidden = not self.hidden
                    self.root.attributes("-alpha", 0.0 if self.hidden else self.settings["alpha"])
            (self.keys.add if pressed else self.keys.discard)(vk)

    def save(self):
        self.settings.update(x=self.root.winfo_x(), y=self.root.winfo_y())
        try:
            with open(SETTINGS, "w", encoding="utf-8") as fh:
                json.dump(self.settings, fh)
        except OSError:
            pass

    def quit(self):
        self.root.destroy()

    def tick(self):
        while True:
            try:
                item = self.source.get_nowait()
            except queue.Empty:
                break
            if item is None:  # the bridge stopped
                self.closed = True
                self.root.after(CLOSE_AFTER_BRIDGE_S * 1000, self.quit)
                continue
            try:
                self.link.take(json.loads(item))
            except (ValueError, AttributeError):
                pass
        self.hotkeys()
        self.draw()
        user32.SetWindowPos(self.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
        self.root.after(REFRESH_MS, self.tick)

    # --- content
    def draw(self):
        lines = self.lines(time.time())
        t = self.text
        t.configure(state="normal")
        t.delete("1.0", "end")
        for i, line in enumerate(lines):
            for text, tag in line:
                t.insert("end", text, tag)
            if i < len(lines) - 1:
                t.insert("end", "\n")
        t.configure(height=len(lines), state="disabled")

    def lines(self, now):
        L, out = self.link, []
        me = L.me.get("machine", {})
        state, since = L.link
        live = state == "connected" and now - L.last_event < 3
        status = ("● LIVE", "tx") if live else (("○ BRIDGE STOPPED", "bad") if self.closed else ("○ " + state.upper(), "warn"))
        wire = f"{L.me.get('wire', '?')} {'encrypted' if L.me.get('encrypted') else 'NOT encrypted'}"
        out.append([(" X4 CO-OP LINK  ", "head"), status, (f"  {wire}", "dim"), (f"   {clock(now)}", "dim")])
        if self.moving:
            out.append([(" MOVE MODE: drag me, then Ctrl+Shift+F12 to lock", "move")])
        x4 = f"X4 pid {L.x4.get('pid')}" if L.x4 else "X4 not connected"
        out.append([(" THIS PC  ", "tx"), (short(me.get("host", "?"), 18), "head"),
                    (f"  pid {me.get('pid', '?')}  {L.me.get('role', '?')}  ", "text"), (x4, "text" if L.x4 else "warn")])
        out.append([("   udp ", "dim"), (f"{L.me.get('udp_bind', '?')}", "text"), ("  sends from ", "dim"),
                    (str(L.me.get("local", "?")), "text")])
        p = L.partner
        if p:
            out.append([(" PARTNER  ", "rx"), (short(p.get("host"), 18), "head"), (f"  pid {p.get('pid')}  ", "text"),
                        (short(p.get("os"), 26), "dim")])
            rtt = f"rtt {L.rtts[-1]:.0f} ms (min {min(L.rtts):.0f})" if L.rtts else "rtt …"
            up = time.strftime("%H:%M:%S", time.gmtime(now - since)) if live and since else "-"
            out.append([("   from ", "dim"), (str(L.partner_from), "text"), (f"   {rtt}   up {up}", "text")])
        else:
            out.append([(" PARTNER  ", "rx"), ("not heard yet", "warn")])
            out.append([("", "text")])
        (tp, tk_), (rp, rk) = L.rate("tx", now), L.rate("rx", now)
        out.append([(" TX ", "tx"), (f"{tp:5.1f} pkt/s {tk_:5.1f} KB/s {L.totals['tx']:>7}", "text"),
                    ("   RX ", "rx"), (f"{rp:5.1f} pkt/s {rk:5.1f} KB/s {L.totals['rx']:>7}", "text")])
        out += self.ship_lines("this PC's ship, as sent", "tx", now)
        out += self.ship_lines("partner's ship, as received", "rx", now)
        a, b = L.ship["tx"], L.ship["rx"]
        if a and b and a[1].get("sector") == b[1].get("sector"):
            d = math.dist(*[[num(s[1].get(k), 0) for k in "xyz"] for s in (a, b)])
            out.append([("   between the ships ", "dim"), (f"{d:,.1f} m", "head"), ("  (same sector)", "dim")])
        out.append([(" ── hits, kills, chat " + "─" * 50, "dim")])
        for wall, d, g in list(L.combat)[-3:]:
            what = {"D": f"hit {g.get('code')} hull {g.get('hull')}%", "K": f"killed {g.get('code')}",
                    "F": f"firing at {g.get('code')}", "M": f"{g.get('name')}: {g.get('text')}"}[g["kind"]]
            out.append([(f"   {clock(wall)} ", "dim"), (d, d), (f" {g['kind']} {short(what, 46)}", "text")])
        if not L.combat:
            out.append([("   none yet", "dim")])
        out.append([(" ── on the wire " + "─" * 56, "dim")])
        for wall, d, ev, kind in list(L.wire)[-4:]:
            h = ev.get("hdr", {})
            raw = ev.get("hex", "")[:24]
            out.append([(f"   {clock(wall)} ", "dim"), (d, d), (f" {ev.get('udp_len', 0):>4}B {kind or '?'} ", "text"),
                        (f"#{h.get('counter', '-'):<6} ", "dim"),
                        (" ".join(raw[i:i + 2] for i in range(0, len(raw), 2)), "text")])
        if L.tcp:
            wall, ev = L.tcp
            what = f"tcp {ev.get('what')} {ev.get('remote') or ev.get('local')}"
            if ev.get("bytes"):
                what += f"  {ev['bytes'] / 1e6:.1f} MB"
            out.append([(f"   {clock(wall)} ", "dim"), (short(what, 56), "warn")])
        if L.error and now - L.error[0] < 10:
            out.append([(f"   {clock(L.error[0])} ", "dim"), (short(L.error[1], 56), "bad")])
        return out

    def ship_lines(self, title, d, now):
        s = self.link.ship[d]
        lines = [[(f" ── {title} " + "─" * (67 - len(title)), "dim")]]
        if not s:
            return lines + [[("   no ship data yet (in a ship, /x4coop net?)", "dim")], [("", "text")]]
        wall, g = s
        speed = math.sqrt(sum(num(g.get(k), 0) ** 2 for k in ("vx", "vy", "vz")))
        hull, shield = g.get("hull") or "?", g.get("shield") or "?"
        lines.append([("   ", "text"), (short(g.get("name"), 22), "head"), (f"  {g.get('idcode') or ''}", "dim"),
                      (f"  hull {hull}%  shield {shield}%", "text"),
                      (f"  {(now - wall) * 1000:4.0f} ms ago", "dim")])
        pos = " ".join(f"{num(g.get(k), 0):9.1f}" for k in "xyz")
        lines.append([("   pos ", "dim"), (pos, "text"), (f"  {speed:6.1f} m/s", "text"),
                      (f"  game t {num(g.get('t'), 0):.1f}", "dim")])
        return lines


def read_stdin(q):
    for raw in sys.stdin.buffer:
        q.put(raw.decode("utf-8", "replace"))
    q.put(None)


def follow(path, q):
    """Reads the trace from its start (the bindings and partner are recorded once, early), then keeps up."""
    while not os.path.exists(path):
        time.sleep(0.2)
    with open(path, encoding="utf-8") as fh:
        partial = ""
        while True:
            chunk = fh.readline()
            if not chunk:
                time.sleep(0.05)
                continue
            partial += chunk
            if partial.endswith("\n"):
                q.put(partial)
                partial = ""


def main(argv=None):
    p = argparse.ArgumentParser(description="X4 Co-op telemetry overlay")
    p.add_argument("--follow", metavar="TRACE", help="watch a trace file instead of reading the bridge's feed")
    p.add_argument("--exit-after", type=float, help="close after this many seconds (tests)")
    args = p.parse_args(argv)
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)  # sharp text on scaled displays
    except (AttributeError, OSError):
        pass
    q = queue.Queue()
    if args.follow:
        threading.Thread(target=follow, args=(args.follow, q), daemon=True).start()
    else:
        threading.Thread(target=read_stdin, args=(q,), daemon=True).start()
    Overlay(q, args.exit_after).root.mainloop()


if __name__ == "__main__":
    main()
