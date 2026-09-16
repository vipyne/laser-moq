#!/usr/bin/env python3
"""Rough ASCII map of where the laser-moq deployment actually is.

Geolocates each endpoint via ipinfo.io, probes TCP RTT from this machine, and
draws the lot on a world map, plus schematic per-protocol media-path diagrams.
Use it to double-check the relay and HLS origin are where you think they are.

Markers:
    P  publisher   — this machine (run it on the box wired to the LaserDisc
                     for the map to be truthful)
    R  moq relay   — host parsed from $MOQ_RELAY_URL (never stored in the repo)
    H  hls origin  — RTMP ingest :1935 in, LL-HLS :443 out
    S  subscriber  — the viewer page host (geolocates to a CDN edge near you,
                     not where the site "lives")

Usage:
    export MOQ_RELAY_URL=https://your-relay.example.com/anon
    python3 scripts/endpoint_map.py
    python3 scripts/endpoint_map.py --no-probe
    python3 scripts/endpoint_map.py --demo          # offline, canned data
    python3 scripts/endpoint_map.py --from-run      # offline, last measured run
    python3 scripts/endpoint_map.py --from-run -2   # second-to-last run

--from-run renders from the coarse geo the measurement harness stores per run
in site/results/data.json (cities and coordinates only — no IPs or hostnames
are ever committed), annotated with that run's measured glass-to-glass p50s.

Stdlib only. Sends only endpoint IPs (public infrastructure) to ipinfo.io.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import socket
import sys
import time
import urllib.request
from urllib.parse import urlparse

HLS_HOST_DEFAULT = "hls-laserdisc.vanessa-dev.com"
PAGE_HOST_DEFAULT = "moq-laserdisc.vanessa-dev.com"

# Equirectangular world, 72 cols x 24 rows: 5 deg/col from 180W, 7.5 deg/row from 90N.
# Land is stored as per-row column spans — coarse on purpose.
LAND: dict[int, list[tuple[int, int]]] = {
    1: [(24, 32)],
    2: [(24, 31), (40, 44), (46, 70)],
    3: [(3, 8), (12, 24), (25, 30), (39, 46), (46, 71)],
    4: [(10, 24), (34, 36), (38, 48), (48, 71)],
    5: [(8, 24), (34, 48), (48, 70)],
    6: [(9, 23), (34, 46), (46, 62), (62, 64)],
    7: [(10, 22), (33, 46), (46, 50), (52, 62), (63, 64)],
    8: [(12, 20), (32, 46), (46, 50), (48, 54), (54, 62)],
    9: [(12, 17), (32, 46), (48, 53), (55, 61)],
    10: [(14, 18), (30, 46), (49, 51), (55, 62)],
    11: [(16, 20), (32, 44), (55, 64)],
    12: [(16, 26), (34, 42), (56, 66)],
    13: [(18, 27), (34, 42), (61, 64)],
    14: [(18, 26), (34, 40), (59, 67)],
    15: [(18, 26), (34, 39), (58, 67)],
    16: [(18, 23), (35, 37), (59, 66)],
    17: [(18, 22), (68, 69)],
    18: [(18, 21), (67, 68)],
    19: [(19, 20)],
    22: [(8, 62)],
    23: [(4, 66)],
}
MAP_W, MAP_H = 72, 24


def project(lat: float, lon: float) -> tuple[int, int]:
    row = min(MAP_H - 1, max(0, int((90 - lat) / 7.5)))
    col = min(MAP_W - 1, max(0, int((lon + 180) / 5)))
    return row, col


def render_map(markers: dict[str, tuple[float, float]]) -> str:
    grid = [[" "] * MAP_W for _ in range(MAP_H)]
    for row, spans in LAND.items():
        for c1, c2 in spans:
            for c in range(c1, min(c2 + 1, MAP_W)):
                grid[row][c] = "."
    for label, (lat, lon) in markers.items():
        r, c = project(lat, lon)
        # Probe nearby cells if another marker already sits here.
        for dr, dc in ((0, 0), (0, 1), (0, -1), (1, 0), (-1, 0), (0, 2)):
            rr, cc = r + dr, c + dc
            if 0 <= rr < MAP_H and 0 <= cc < MAP_W and not grid[rr][cc].isupper():
                grid[rr][cc] = label
                break
    lines = ["".join(row).rstrip() for row in grid]
    return "\n".join(f"│{line:<{MAP_W}}│" for line in lines)


def render_path(title: str, src: dict, mid: dict, dst: dict,
                up_note: str, down_note: str, down_measured: bool) -> str:
    """Schematic (not to scale): media flows src → mid, viewers pull mid → dst.
    `up_note`/`down_note` annotate the two legs; ┊ marks a leg not measured here."""

    def node(n: dict) -> str:
        bits = [n["label"], n.get("place") or "?", n.get("ip") or ""]
        return "◉ " + "  ·  ".join(b for b in bits if b)

    down_bar = "▲" if down_measured else "┊"
    body = [
        "",
        node(src),
        "│",
        f"│  {up_note}",
        "▼",
        node(mid),
        down_bar,
        f"{'│' if down_measured else '┊'}  {down_note}",
        node(dst),
        "",
    ]
    inner = max(len(s) for s in [*body, f"── {title} "]) + 2
    top = f"┌── {title} " + "─" * (inner - len(title) - 4) + "┐"
    out = [top]
    for s in body:
        out.append(f"│ {s:<{inner - 2}} │")
    out.append("└" + "─" * inner + "┘")
    return "\n".join(out)


_geo_cache: dict[str, dict] = {}


def geolocate(ip: str) -> dict:
    if ip not in _geo_cache:
        try:
            with urllib.request.urlopen(f"https://ipinfo.io/{ip}/json", timeout=10) as resp:
                _geo_cache[ip] = json.load(resp)
        except Exception:
            _geo_cache[ip] = {}
    return _geo_cache[ip]


def my_location() -> dict:
    try:
        with urllib.request.urlopen("https://ipinfo.io/json", timeout=10) as resp:
            return json.load(resp)
    except Exception:
        return {}


def tcp_rtt_ms(ip: str, port: int = 443, samples: int = 3) -> float | None:
    best = None
    for _ in range(samples):
        try:
            t = time.time()
            s = socket.create_connection((ip, port), timeout=5)
            rtt = (time.time() - t) * 1000
            s.close()
            best = rtt if best is None else min(best, rtt)
        except OSError:
            return best
    return best


def haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    (lat1, lon1), (lat2, lon2) = a, b
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    h = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6371 * math.asin(math.sqrt(h))


def place(geo: dict) -> str:
    bits = [geo.get("city"), geo.get("region"), geo.get("country")]
    where = ", ".join(b for b in bits if b)
    org = geo.get("org")
    return f"{where} · {org}" if org else (where or "location unknown")


def latlon(geo: dict) -> tuple[float, float] | None:
    loc = geo.get("loc")
    if not loc:
        return None
    try:
        lat, lon = loc.split(",")
        return float(lat), float(lon)
    except ValueError:
        return None


def demo_data() -> tuple[dict, dict[str, dict]]:
    """Canned, clearly-fake data so --demo renders offline (and in tests)."""
    me = {"ip": "203.0.113.7", "city": "Portland", "region": "Oregon",
          "country": "US", "loc": "45.52,-122.68"}
    eps = {
        "R": {"kind": "moq relay", "host": "relay.demo.example", "ip": "198.51.100.20",
              "geo": {"city": "Ashburn", "region": "Virginia", "country": "US",
                      "loc": "39.04,-77.49", "org": "DEMO-NET"},
              "rtt": {443: 71.0}},
        "H": {"kind": "hls origin", "host": "hls.demo.example", "ip": "198.51.100.40",
              "geo": {"city": "Phoenix", "region": "Arizona", "country": "US",
                      "loc": "33.45,-112.07", "org": "DEMO-NET"},
              "rtt": {443: 33.0, 1935: 34.0}},
        "S": {"kind": "subscriber", "host": "page.demo.example", "ip": "198.51.100.60",
              "geo": {"city": "Seattle", "region": "Washington", "country": "US",
                      "loc": "47.61,-122.33", "org": "DEMO-CDN"},
              "rtt": {443: 9.0}},
    }
    return me, eps


def norm_geo(g: dict | None) -> dict:
    """Stored coarse geo ({city,region,country,lat,lon}) → ipinfo-shaped dict
    so place()/latlon() work unchanged."""
    if not g:
        return {}
    out = {k: g[k] for k in ("city", "region", "country") if g.get(k)}
    if g.get("lat") is not None and g.get("lon") is not None:
        out["loc"] = f"{g['lat']},{g['lon']}"
    return out


def p50(values: list[float]) -> float | None:
    if not values:
        return None
    s = sorted(values)
    return s[(len(s) - 1) // 2]


def from_run(data_path: str, idx: int) -> int:
    try:
        data = json.load(open(data_path))
    except (OSError, json.JSONDecodeError) as e:
        print(f"endpoint_map: cannot read {data_path}: {e}", file=sys.stderr)
        return 1
    runs = data.get("runs") or []
    if not runs:
        print(f"endpoint_map: no runs in {data_path}", file=sys.stderr)
        return 1
    try:
        run = runs[idx]
    except IndexError:
        print(f"endpoint_map: run index {idx} out of range (have {len(runs)})", file=sys.stderr)
        return 1
    geo = run.get("geo") or {}
    if not any(geo.values()):
        print(f"endpoint_map: run {run.get('started_utc', '?')} has no stored geo "
              "(recorded by the harness since the geo change; older runs have none)",
              file=sys.stderr)
        return 1

    kinds = {"P": ("publisher", "publisher"), "R": ("relay", "moq relay"),
             "H": ("hls", "hls origin"), "S": ("page", "subscriber")}
    markers: dict[str, tuple[float, float]] = {}
    legend: list[str] = []
    for letter, (key, label) in kinds.items():
        g = norm_geo(geo.get(key))
        ll = latlon(g)
        if ll:
            markers[letter] = ll
        legend.append(f"{letter}  {label:<11} {place(g)}")

    g2g = {t: p50([s["glass_to_glass_ms"] for s in run.get("samples", [])
                   if s.get("transport") == t and s.get("method") == "clock-ocr"])
           for t in ("moq", "hls")}

    print(f"  run {run.get('started_utc', '?')} · source={run.get('source', '?')} · "
          f"machine={run.get('machine', '?')}"
          + (f" · {run['notes']}" if run.get("notes") else ""))
    print("  (coarse geo stored with the run — cities only, no IPs or hostnames)\n")
    print(f"┌{'─' * MAP_W}┐")
    print(render_map(markers))
    print(f"└{'─' * MAP_W}┘")
    print()
    for line in legend:
        print(f"  {line}")
    print()
    p_node = {"label": "P publisher", "place": place(norm_geo(geo.get("publisher"))), "ip": ""}
    viewer = {"label": "viewer", "place": "the measuring machine (this run)", "ip": ""}
    for title, letter, key, t in (("MoQ media path", "R", "relay", "moq"),
                                  ("LL-HLS media path", "H", "hls", "hls")):
        mid = {"label": f"{letter} {kinds[letter][1]}",
               "place": place(norm_geo(geo.get(key))), "ip": ""}
        ms = g2g[t]
        down = (f"~{ms:.0f} ms glass-to-glass p50 measured in this run"
                if ms is not None else "no clock-ocr samples in this run")
        print(render_path(title, p_node, mid, viewer,
                          "publisher → " + kinds[letter][1] + " (RTT not stored per run)",
                          down, down_measured=ms is not None))
        print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hls", default=HLS_HOST_DEFAULT, help="HLS origin host")
    ap.add_argument("--page", default=PAGE_HOST_DEFAULT, help="viewer page host")
    ap.add_argument("--no-probe", action="store_true", help="skip TCP RTT probes")
    ap.add_argument("--demo", action="store_true", help="render with canned offline data")
    ap.add_argument("--from-run", nargs="?", const=-1, default=None, type=int,
                    metavar="N", help="render run N from the results data (default -1, the last); offline")
    ap.add_argument("--data", default="site/results/data.json",
                    help="results data file for --from-run")
    args = ap.parse_args()

    if args.from_run is not None:
        return from_run(args.data, args.from_run)

    if args.demo:
        me, endpoints = demo_data()
    else:
        relay_url = os.environ.get("MOQ_RELAY_URL")
        if not relay_url:
            print("MOQ_RELAY_URL not set (e.g. export MOQ_RELAY_URL="
                  "https://your-relay.example.com/anon)", file=sys.stderr)
            return 1
        relay_host = urlparse(relay_url).hostname
        if not relay_host:
            print(f"endpoint_map: cannot parse a host out of MOQ_RELAY_URL", file=sys.stderr)
            return 1
        endpoints = {
            "R": {"kind": "moq relay", "host": relay_host, "probe": [443]},
            "H": {"kind": "hls origin", "host": args.hls, "probe": [443, 1935]},
            "S": {"kind": "subscriber", "host": args.page, "probe": [443]},
        }
        for e in endpoints.values():
            try:
                e["ip"] = socket.gethostbyname(e["host"])
            except OSError:
                e["ip"] = None
            e["geo"] = geolocate(e["ip"]) if e["ip"] else {}
            e["rtt"] = {}
            if e["ip"] and not args.no_probe:
                for port in e["probe"]:
                    ms = tcp_rtt_ms(e["ip"], port)
                    if ms is not None:
                        e["rtt"][port] = ms
        me = my_location()

    def rtts(e: dict) -> str:
        r = e.get("rtt") or {}
        if not r:
            return ""
        return "  rtt " + " ".join(f":{p} {ms:.0f}ms" for p, ms in sorted(r.items()))

    markers: dict[str, tuple[float, float]] = {}
    legend: list[str] = []
    if latlon(me):
        markers["P"] = latlon(me)
    legend.append(f"P  {'publisher':<11} {me.get('ip', '?'):<16} "
                  f"{place(me)}  (this machine)")
    notes = {"R": "", "H": ":1935 RTMP in, :443 LL-HLS out",
             "S": "CDN edge near you — the page, not a media hop"}
    for letter in ("R", "H", "S"):
        e = endpoints[letter]
        ll = latlon(e["geo"])
        if ll:
            markers[letter] = ll
        note = f"  ({notes[letter]})" if notes[letter] else ""
        legend.append(f"{letter}  {e['kind']:<11} {e.get('ip') or e['host']:<16} "
                      f"{place(e['geo'])}{rtts(e)}{note}")

    if args.demo:
        print("  (--demo: canned data, nothing was resolved, probed, or geolocated)\n")
    print(f"┌{'─' * MAP_W}┐")
    print(render_map(markers))
    print(f"└{'─' * MAP_W}┘")
    print()
    for line in legend:
        print(f"  {line}")
    print()
    print("  paths:  moq     P (publisher) ──▶ R (relay) ◀── viewers")
    print("          ll-hls  P (publisher) ──▶ H (:1935) ◀── viewers (:443)")
    print("          page    viewers load the site itself from S")

    # Schematic path diagrams. The viewer leg can only be measured in the
    # viewer's browser (that's what /results is for), so it's drawn dashed.
    p_node = {"label": "P publisher", "place": place(me).split(" · ")[0],
              "ip": me.get("ip")}
    viewers = {"label": "viewers", "place": "wherever the audience is", "ip": ""}
    r, h = endpoints["R"], endpoints["H"]
    r_rtt = (r.get("rtt") or {}).get(443)
    up = (f"~{r_rtt:.0f} ms   publisher → relay (TCP connect, from this machine)"
          if r_rtt else "publisher → relay (RTT not probed)")
    print("\n" + render_path(
        "MoQ media path",
        p_node,
        {"label": "R moq relay", "place": place(r["geo"]).split(" · ")[0],
         "ip": r.get("ip") or r["host"]},
        viewers,
        up,
        "viewers → relay  (measured in the viewer's browser — see /results)",
        down_measured=False,
    ))
    h_rtt = (h.get("rtt") or {}).get(1935)
    up = (f"~{h_rtt:.0f} ms   publisher → origin :1935 RTMP (TCP connect, from this machine)"
          if h_rtt else "publisher → origin :1935 RTMP (RTT not probed)")
    print("\n" + render_path(
        "LL-HLS media path",
        p_node,
        {"label": "H hls origin", "place": place(h["geo"]).split(" · ")[0],
         "ip": h.get("ip") or h["host"]},
        viewers,
        up,
        "viewers → origin :443 LL-HLS  (measured in the viewer's browser — see /results)",
        down_measured=False,
    ))
    print("\n  P is wherever this script runs — run it on the publisher box "
          "(the machine wired to the LaserDisc)\n  for the map to tell the truth.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
