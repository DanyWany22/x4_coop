#!/usr/bin/env python3
"""
Pretend to be a co-op partner, so the whole network path can be tested on one PC.

    python x4_coop_bridge.py --host     # terminal 1: your bridge (X4 running, /x4coop net)
    python fake_peer.py                 # terminal 2: joins 127.0.0.1:47810

Modes:
  echo  (default)  mirrors your own ship back to you, shifted by --offset (sector axes, metres).
                   Like the in-game ghost, but through the bridge, UDP and the pipe.
  orbit            circles the spot where you were when it first heard from you.
                   If the ship flies sideways or backwards, try --yaw-sign -1 (the in-game
                   probe in the debug log reports the engine's convention).

It speaks the same protocol as the bridge and answers pings, so /x4coop status shows an RTT.
"""
import argparse
import collections
import math
import socket
import sys
import time

MAGIC = b"X4C1 "


def parse_address(text, default_port):
    host, sep, port = text.rpartition(":")
    if not sep:
        host, port = text, ""
    return socket.gethostbyname(host), int(port) if port else default_port


def parse_snapshot(msg):
    f = msg.split("|")
    if len(f) < 15 or f[0] != "S":
        return None
    try:
        nums = [float(v) for v in f[5:14]]
    except ValueError:
        return None
    return {"sector": f[3], "ship": f[4], "pos": nums[0:3], "rot": nums[3:6], "vel": nums[6:9], "name": f[14]}


def snapshot(seq, t, sector, ship, pos, rot, vel, name):
    return ("S|%d|%.4f|%s|%s|%.2f|%.2f|%.2f|%.5f|%.5f|%.5f|%.2f|%.2f|%.2f|%s"
            % (seq, t, sector, ship, *pos, *rot, *vel, name))


def main(argv=None):
    p = argparse.ArgumentParser(description="Fake X4 co-op partner for single-PC testing")
    p.add_argument("--join", default="127.0.0.1:47810", help="bridge to talk to (default 127.0.0.1:47810)")
    p.add_argument("--mode", choices=["echo", "orbit"], default="echo")
    p.add_argument("--offset", default="150,0,0", help="echo offset x,y,z in metres (default 150,0,0)")
    p.add_argument("--delay", type=float, default=0.0, help="extra one-way delay in seconds")
    p.add_argument("--rate", type=float, default=20.0, help="snapshots per second")
    p.add_argument("--radius", type=float, default=400.0, help="orbit radius in metres")
    p.add_argument("--speed", type=float, default=150.0, help="orbit speed in m/s")
    p.add_argument("--yaw-sign", type=float, default=1.0, help="orbit heading sign (+1 or -1)")
    p.add_argument("--name", default="Fake Partner")
    args = p.parse_args(argv)

    bridge = parse_address(args.join, 47810)
    offset = [float(v) for v in args.offset.split(",")]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
    sock.bind(("0.0.0.0", 0))
    sock.setblocking(False)

    start = time.monotonic()
    outbox = collections.deque()  # (release_time, bytes)
    latest = None                 # player's newest snapshot
    latest_at = 0.0
    orbit_center = None
    seq = 0
    next_send = next_keepalive = next_report = 0.0
    received = 0
    print(f"fake partner ({args.mode}) talking to bridge {bridge[0]}:{bridge[1]}; Ctrl+C to stop", flush=True)

    def send(msg, now):
        outbox.append((now + args.delay, MAGIC + msg.encode("utf-8")))

    try:
        while True:
            now = time.monotonic()
            while True:
                try:
                    data, _ = sock.recvfrom(65535)
                except (BlockingIOError, ConnectionResetError):
                    break
                if not data.startswith(MAGIC):
                    continue
                msg = data[len(MAGIC):].decode("utf-8", "replace")
                if msg.startswith("P|"):
                    send("Q|" + msg[2:], now)
                    continue
                s = parse_snapshot(msg)
                if s:
                    received += 1
                    latest, latest_at = s, now
                    if orbit_center is None or orbit_center["sector"] != s["sector"]:
                        orbit_center = {"sector": s["sector"], "pos": list(s["pos"])}

            if now >= next_keepalive:
                next_keepalive = now + 1.0
                outbox.append((now, MAGIC + b"H"))

            if now >= next_send and latest and now - latest_at < 2.0:
                next_send = now + 1.0 / args.rate
                seq += 1
                t = now - start
                if args.mode == "echo":
                    pos = [a + b for a, b in zip(latest["pos"], offset)]
                    send(snapshot(seq, t, latest["sector"], latest["ship"], pos, latest["rot"], latest["vel"], args.name), now)
                else:
                    w = args.speed / args.radius
                    th = w * t
                    c = orbit_center["pos"]
                    pos = [c[0] + args.radius * math.cos(th), c[1], c[2] + args.radius * math.sin(th)]
                    vel = [-args.speed * math.sin(th), 0.0, args.speed * math.cos(th)]
                    rot = [args.yaw_sign * math.atan2(vel[0], vel[2]), 0.0, 0.0]
                    send(snapshot(seq, t, orbit_center["sector"], latest["ship"], pos, rot, vel, args.name), now)

            while outbox and outbox[0][0] <= now:
                sock.sendto(outbox.popleft()[1], bridge)

            if now >= next_report:
                next_report = now + 5.0
                if latest and now - latest_at < 2.0:
                    x, y, z = latest["pos"]
                    print(f"player {latest['name']} in {latest['sector']} at ({x:.0f}, {y:.0f}, {z:.0f}); "
                          f"{received} snapshots received, {seq} sent", flush=True)
                else:
                    print("no snapshots from the player yet (is X4 in a ship, in net mode, bridge running?)", flush=True)
            time.sleep(0.002)
    except KeyboardInterrupt:
        print("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
