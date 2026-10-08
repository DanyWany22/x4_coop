#!/usr/bin/env python3
"""
Puts two machines' bridge traces (x4_coop_bridge.py --trace) side by side, as evidence that the co-op link is
real: the same datagrams leave one PC and arrive at the other byte for byte (matched by their HMAC tags), how
long they took, and what each PC's own simulation was doing at the same moments (ship positions, speeds,
hull, each machine's game clock, hits and kills).

    python x4_coop_trace_report.py PC.jsonl LAPTOP.jsonl [--html report.html]

Clocks: the two PCs' clocks differ. The offset is estimated from the packets themselves (the fastest trip each
way is assumed to take equally long), and the partner's times are shifted onto the first trace's clock.
"""
import argparse
import html
import json
import math
import statistics
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from x4_coop_bridge import decode_game  # noqa: E402


def load(path):
    events = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                events.append(json.loads(line))
            except ValueError:
                pass  # a line cut off when the bridge was closed
    start = next((e for e in events if e.get("ev") == "start"), {})
    return {"path": path, "events": events, "start": start, "machine": start.get("machine", {}),
            "tx": [e for e in events if e.get("ev") == "pkt" and e.get("dir") == "tx"],
            "rx": [e for e in events if e.get("ev") == "pkt" and e.get("dir") == "rx"],
            "peers": [e for e in events if e.get("ev") == "peer"],
            "tcp": [e for e in events if e.get("ev") == "tcp"]}


def match(sender, receiver):
    """Pairs (sent on sender, received on receiver) of the same datagram, by its HMAC tag."""
    arrived = {}
    for e in receiver["rx"]:
        tag = e.get("hdr", {}).get("tag")
        if tag and tag not in arrived:
            arrived[tag] = e
    pairs = [(e, arrived[e["hdr"]["tag"]]) for e in sender["tx"] if e.get("hdr", {}).get("tag") in arrived]
    if pairs:  # sent while the receiver was recording, for the loss figure
        first, last = pairs[0][0]["wall"], pairs[-1][0]["wall"]
        window = [e for e in sender["tx"] if first <= e["wall"] <= last]
    else:
        window = []
    return pairs, window


def ships(trace, kind="tx"):
    """(wall, fields) of each S message this trace sent (its own ship) or received (the partner's ship)."""
    out = []
    for e in trace[kind]:
        g = decode_game(e.get("msg"))
        if g["kind"] == "S" and not (e.get("verdict") or "").startswith(("rejected", "ignored", "dropped")):
            out.append((e["wall"], g))
    return out


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def speed(g):
    return math.sqrt(sum(num(g.get(k)) ** 2 for k in ("vx", "vy", "vz")))


def at(series, wall):
    """The latest entry of a time series at or before wall."""
    best = None
    for item in series:
        if item[0] > wall:
            break
        best = item
    return best


def clock(wall):
    import time
    return time.strftime("%H:%M:%S", time.localtime(wall)) + f".{int(wall % 1 * 1000):03d}"


def analyse(a, b):
    ab, ab_window = match(a, b)
    ba, ba_window = match(b, a)
    d_ab = [rx["wall"] - tx["wall"] for tx, rx in ab]   # = trip A->B + (B's clock - A's clock)
    d_ba = [rx["wall"] - tx["wall"] for tx, rx in ba]   # = trip B->A - (B's clock - A's clock)
    offset = (min(d_ab) - min(d_ba)) / 2 if d_ab and d_ba else 0.0  # B's clock minus A's
    trip_ab = [d - offset for d in d_ab]
    trip_ba = [d + offset for d in d_ba]
    return {"ab": ab, "ba": ba, "ab_window": ab_window, "ba_window": ba_window, "offset": offset,
            "trip_ab": trip_ab, "trip_ba": trip_ba,
            "same_text": sum(tx.get("msg") == rx.get("msg") for tx, rx in ab + ba),
            "same_bytes": sum(tx.get("hex") == rx.get("hex") for tx, rx in ab + ba),
            "rtt_a": [p["rtt_ms"] for p in a["peers"] if p.get("rtt_ms") is not None],
            "rtt_b": [p["rtt_ms"] for p in b["peers"] if p.get("rtt_ms") is not None],
            "ship_a": ships(a), "ship_b": [(w - offset, g) for w, g in ships(b)]}


def printable(hex_text):
    """Recorded bytes as text, non-printable ones as dots: shows the X4C2 magic and our header."""
    return "".join(chr(b) if 32 <= b < 127 else "." for b in bytes.fromhex(hex_text))


def example(pairs):
    """A matched pair carrying game state (S) if there is one."""
    return next((p for p in pairs if (p[0].get("msg") or "").startswith("S|")), pairs[0])


def ms(values, how=statistics.median):
    return f"{how(values) * 1000:.1f} ms" if values else "-"


def machine_line(t):
    m, s = t["machine"], t["start"]
    local = t["tx"][0].get("local") if t["tx"] else s.get("local")  # a host learns its route once a partner talks
    return (f"{m.get('host', '?')} (pid {m.get('pid', '?')}, {m.get('os', '?')}), role {s.get('role', '?')}, "
            f"UDP bound {s.get('udp_bind', '?')}, sends from {local or '?'}, "
            f"{'encrypted' if s.get('encrypted') else 'NOT encrypted'} {s.get('wire', '')}")


def combat(sender, receiver, sender_shift, receiver_shift):
    """
    Hits, kills and shots the sender's PC sent: (time on A's clock, fields, seconds until the receiver had it).
    A shift is what to subtract from that trace's clock to get A's (0 for A, the offset for B).
    """
    arrived = {e.get("hdr", {}).get("tag"): e["wall"] for e in receiver["rx"]}
    rows = []
    for e in sender["tx"]:
        g = decode_game(e.get("msg"))
        if g["kind"] in ("D", "K", "F"):
            sent = e["wall"] - sender_shift
            got = arrived.get(e.get("hdr", {}).get("tag"))
            rows.append((sent, g, None if got is None else got - receiver_shift - sent))
    return rows


def text_report(a, b, r):
    A, B = a["machine"].get("host", "A"), b["machine"].get("host", "B")
    out = ["X4 CO-OP LINK: TWO-MACHINE TRACE REPORT", "",
           f"A  {machine_line(a)}", f"B  {machine_line(b)}"]
    seen_by_a = {p["machine"].get("host") for p in a["peers"]}
    seen_by_b = {p["machine"].get("host") for p in b["peers"]}
    distinct = (a["machine"].get("host"), a["machine"].get("pid")) != (b["machine"].get("host"), b["machine"].get("pid"))
    out += [f"   A's bridge heard from: {', '.join(sorted(map(str, seen_by_a))) or '-'};"
            f" B's bridge heard from: {', '.join(sorted(map(str, seen_by_b))) or '-'}",
            f"   distinct processes: {'yes' if distinct else 'NO (same machine and pid)'};"
            f" distinct machines: {'yes' if A != B else 'no (same hostname: a local test)'}", ""]
    n = len(r["ab"]) + len(r["ba"])
    out += ["PACKETS (matched by their 128-bit HMAC tag)",
            f"   A->B: {len(r['ab'])} of {len(r['ab_window'])} sent arrived "
            f"({100 * len(r['ab']) / max(1, len(r['ab_window'])):.1f}%),"
            f" one-way trip median {ms(r['trip_ab'])}, fastest {ms(r['trip_ab'], min)}",
            f"   B->A: {len(r['ba'])} of {len(r['ba_window'])} sent arrived "
            f"({100 * len(r['ba']) / max(1, len(r['ba_window'])):.1f}%),"
            f" one-way trip median {ms(r['trip_ba'])}, fastest {ms(r['trip_ba'], min)}",
            f"   round trip measured by the bridges' keepalives: A {statistics.median(r['rtt_a']) if r['rtt_a'] else '-'} ms,"
            f" B {statistics.median(r['rtt_b']) if r['rtt_b'] else '-'} ms (medians)",
            f"   clock offset B - A: {r['offset'] * 1000:+.1f} ms (estimated; B's times below are shifted onto A's clock)",
            f"   decrypted text identical on both sides: {r['same_text']} of {n};"
            f" recorded wire bytes identical: {r['same_bytes']} of {n}", ""]
    for label, (tx, rx) in (("A->B", example(r["ab"])), ("B->A", example(r["ba"]))) if r["ab"] and r["ba"] else ():
        h = tx["hdr"]
        out += [f"   example {label}: session {h.get('session')} counter {h.get('counter')} tag {h.get('tag')}",
                f"      sent     {clock(tx['wall'])} {tx['local']} -> {tx['remote']}  {tx['udp_len']} B UDP payload",
                f"      received {clock(rx['wall'])} {rx['remote']} -> {rx['local']}  (receiver's clock)",
                f"      bytes    {tx['hex'][:64]}",
                f"      as text  {printable(tx['hex'][:64])}   (magic, HMAC tag, then session:counter:time)",
                f"      message  {tx.get('msg', '')[:100]}"]
    out.append("")
    sa, sb = r["ship_a"], r["ship_b"]
    if sa and sb:
        t0, t1 = max(sa[0][0], sb[0][0]), min(sa[-1][0], sb[-1][0])
        name_a, name_b = (str(x[-1][1].get("name") or "?")[:16] for x in (sa, sb))
        out += [f"BOTH SIMULATIONS RUNNING AT ONCE: {max(0.0, t1 - t0):.1f} s overlap"
                f" ({len(sa)} ship states from A, {len(sb)} from B; each PC's own ship, as it sent it)",
                f"   {'time (A clock)':<14} | {'A: ' + name_a + ' pos (m)':<28} {'m/s':>6} {'hull':>4} {'game t':>8}"
                f" | {'B: ' + name_b + ' pos (m)':<28} {'m/s':>6} {'hull':>4} {'game t':>8}"]
        steps = 12
        for i in range(steps + 1):
            w = t0 + (t1 - t0) * i / steps
            ea, eb = at(sa, w), at(sb, w)
            if not (ea and eb):
                continue
            row = []
            for _, g in (ea, eb):
                pos = " ".join(f"{num(g.get(k)):9.1f}" for k in "xyz")
                row.append(f"{pos:<28} {speed(g):6.1f} {g.get('hull') or '?':>4} {num(g.get('t')):8.2f}")
            out.append(f"   {clock(w):<14} | {row[0]} | {row[1]}")
        out.append("")
    rows = [("A",) + x for x in combat(a, b, 0, r["offset"])] + [("B",) + x for x in combat(b, a, r["offset"], 0)]
    rows.sort(key=lambda x: x[1])
    out.append("HITS, KILLS AND SHOTS (which PC sent it, when it reached the other PC)")
    for who, w, g, delay in rows[:40]:
        what = {"D": f"hit {g.get('code')} -> hull {g.get('hull')}%", "K": f"killed {g.get('code')}",
                "F": f"firing at {g.get('code')}"}[g["kind"]]
        arrived = f"arrived after {delay * 1000:.1f} ms" if delay is not None else "not seen arriving"
        out.append(f"   {clock(w)}  {who}  {g['kind']}  {what:<34} {arrived}")
    if not rows:
        out.append("   none in these traces")
    tcp = [f"   {a['machine'].get('host')}: {e['what']} {e.get('remote') or e.get('local')} {e.get('bytes', '')}"
           for e in a["tcp"]] + [f"   {b['machine'].get('host')}: {e['what']} {e.get('remote') or e.get('local')}"
                                 f" {e.get('bytes', '')}" for e in b["tcp"]]
    if tcp:
        out += ["", "SAVE TRANSFER (TCP)"] + tcp
    return "\n".join(out)


def svg_tracks(sa, sb):
    pts = [(num(g.get("x")), num(g.get("z"))) for _, g in sa + sb]
    if not pts:
        return "<p>No ship states.</p>"
    xs, zs = [p[0] for p in pts], [p[1] for p in pts]
    span = max(max(xs) - min(xs), max(zs) - min(zs), 1.0)
    W = 420

    def path(series):
        return " ".join(f"{20 + (num(g.get('x')) - min(xs)) / span * (W - 40):.1f},"
                        f"{W - 20 - (num(g.get('z')) - min(zs)) / span * (W - 40):.1f}" for _, g in series)
    return (f'<svg viewBox="0 0 {W} {W}" class="chart"><rect width="{W}" height="{W}" class="plot"/>'
            f'<polyline points="{path(sa)}" class="a"/><polyline points="{path(sb)}" class="b"/>'
            f'<text x="10" y="16">top-down (x, z), {span:,.0f} m across</text></svg>')


def svg_speed(sa, sb, events):
    series = [(w, speed(g)) for w, g in sa] + [(w, speed(g)) for w, g in sb]
    if not series:
        return ""
    t0, t1 = min(s[0] for s in series), max(s[0] for s in series)
    top = max(max(s[1] for s in series), 1.0)
    W, H = 840, 220

    def xy(w, v):
        return f"{40 + (w - t0) / max(t1 - t0, 1e-6) * (W - 60):.1f},{H - 25 - v / top * (H - 45):.1f}"
    marks = "".join(f'<line x1="{xy(w, 0).split(",")[0]}" x2="{xy(w, 0).split(",")[0]}" y1="20" y2="{H - 25}" '
                    f'class="mark"><title>{html.escape(t)}</title></line>' for w, t in events)
    return (f'<svg viewBox="0 0 {W} {H}" class="chart"><rect width="{W}" height="{H}" class="plot"/>{marks}'
            f'<polyline points="{" ".join(xy(w, speed(g)) for w, g in sa)}" class="a"/>'
            f'<polyline points="{" ".join(xy(w, speed(g)) for w, g in sb)}" class="b"/>'
            f'<text x="10" y="16">ship speed over time (m/s, max {top:.0f}); orange lines: hits and kills</text></svg>')


def svg_hist(trip_ab, trip_ba):
    values = [v * 1000 for v in trip_ab + trip_ba]
    if not values:
        return ""
    lo, hi = min(values), max(values)
    bins = 30
    width = max((hi - lo) / bins, 0.01)
    W, H = 420, 220

    def counts(vals):
        c = [0] * bins
        for v in vals:
            c[min(bins - 1, int((v * 1000 - lo) / width))] += 1
        return c
    ca, cb = counts(trip_ab), counts(trip_ba)
    top = max(ca + cb + [1])
    bw = (W - 40) / bins
    bars = "".join(f'<rect x="{20 + i * bw:.1f}" y="{H - 25 - n / top * (H - 50):.1f}" width="{bw / 2:.1f}" '
                   f'height="{n / top * (H - 50):.1f}" class="a"/>' for i, n in enumerate(ca))
    bars += "".join(f'<rect x="{20 + i * bw + bw / 2:.1f}" y="{H - 25 - n / top * (H - 50):.1f}" width="{bw / 2:.1f}" '
                    f'height="{n / top * (H - 50):.1f}" class="b"/>' for i, n in enumerate(cb))
    return (f'<svg viewBox="0 0 {W} {H}" class="chart"><rect width="{W}" height="{H}" class="plot"/>{bars}'
            f'<text x="10" y="16">one-way trip, {lo:.1f}–{hi:.1f} ms</text></svg>')


def html_report(a, b, r, text):
    A, B = html.escape(str(a["machine"].get("host", "A"))), html.escape(str(b["machine"].get("host", "B")))
    events = [(w, f"{g['kind']} {g.get('code')}") for w, g, _ in combat(a, b, 0, r["offset"]) +
              combat(b, a, r["offset"], 0) if g["kind"] in ("D", "K")]
    rows = ""
    for tx, rx in sorted(r["ab"][:8] + r["ba"][:8], key=lambda p: p[0]["wall"]):
        rows += (f"<tr><td>{clock(tx['wall'])}</td><td>{html.escape(tx['local'])} → {html.escape(tx['remote'])}</td>"
                 f"<td>{clock(rx['wall'])}</td><td>{tx['hdr'].get('counter')}</td>"
                 f"<td><code>{tx['hex'][:40]}</code></td><td><code>{rx['hex'][:40]}</code></td>"
                 f"<td><code>{html.escape((tx.get('msg') or '')[:60])}</code></td></tr>")
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>X4 Co-op link report</title>
<style>
body{{font:14px system-ui,sans-serif;background:#0b0f14;color:#c9d1d9;margin:24px;max-width:1100px}}
h1{{font-size:20px}} h2{{font-size:16px;margin-top:28px}} code,pre{{font:12px Consolas,monospace}}
pre{{background:#11161d;padding:12px;overflow-x:auto}} .chart{{width:100%;max-width:840px;background:#11161d}}
.plot{{fill:#11161d}} polyline{{fill:none;stroke-width:1.5}} polyline.a{{stroke:#3fb950}} polyline.b{{stroke:#58a6ff}}
rect.a{{fill:#3fb950}} rect.b{{fill:#58a6ff}} .mark{{stroke:#d29922;stroke-width:1}} text{{fill:#8b949e;font-size:12px}}
table{{border-collapse:collapse;font-size:12px}} td,th{{border-bottom:1px solid #222;padding:4px 8px;text-align:left}}
.scroll{{overflow-x:auto}} .a-key{{color:#3fb950}} .b-key{{color:#58a6ff}} .row{{display:flex;gap:16px;flex-wrap:wrap}} .row svg{{max-width:420px}}
</style></head><body>
<h1>X4 Co-op link: <span class="a-key">{A}</span> ⇄ <span class="b-key">{B}</span></h1>
<p><span class="a-key">■ A: {A}, {html.escape(str(a["start"].get("role", "?")))}</span> &nbsp;
<span class="b-key">■ B: {B}, {html.escape(str(b["start"].get("role", "?")))}</span> &nbsp; Times on A's clock
(B's shifted by {r["offset"] * 1000:+.1f} ms). Each line is that PC's own ship, as it sent it.</p>
<div class="row">{svg_tracks(r["ship_a"], r["ship_b"])}{svg_hist(r["trip_ab"], r["trip_ba"])}</div>
<h2>Both ships at once</h2>{svg_speed(r["ship_a"], r["ship_b"], events)}
<h2>The same datagrams on both machines</h2>
<div class="scroll"><table><tr><th>sent</th><th>from → to</th><th>received (other clock)</th><th>counter</th><th>bytes sent</th>
<th>bytes received</th><th>message</th></tr>{rows}</table></div>
<h2>Full report</h2><pre>{html.escape(text)}</pre></body></html>"""


def main(argv=None):
    p = argparse.ArgumentParser(description="Compare two X4 Co-op bridge traces")
    p.add_argument("trace_a")
    p.add_argument("trace_b")
    p.add_argument("--html", metavar="FILE", help="also write an HTML report with charts")
    args = p.parse_args(argv)
    a, b = load(args.trace_a), load(args.trace_b)
    if not a["tx"] or not b["tx"]:
        print("one of the traces has no sent packets; was the bridge connected to its partner?")
        return 1
    if not any(e.get("hdr", {}).get("tag") for e in a["tx"]):
        print("these traces are unencrypted (--no-password): packets can't be matched by tag")
        return 1
    r = analyse(a, b)
    text = text_report(a, b, r)
    print(text)
    if args.html:
        with open(args.html, "w", encoding="utf-8") as fh:
            fh.write(html_report(a, b, r, text))
        print(f"\nHTML report: {args.html}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
