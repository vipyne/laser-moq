# /// script
# requires-python = ">=3.10"
# dependencies = ["matplotlib"]
# ///
"""Grouped bar PNG: MoQ vs HLS encoder-to-glass medians per media type.

Input: JSON mapping media label → run notes string, matched exactly against
runs in site/results/data.json:

    {"graph": {"LaserDisc": "200 prod LD", "VHS": "200 prod vhs", "DVD": "200 prod dvd"}}

Bars are per-run clock-ocr medians; whiskers span that run's min–max samples.
Site palette (MoQ #8ab4ff / HLS #ffb74d on #0b0b0f).

    uv run scripts/graph_media_bars.py graph.json -o media-bars.png
"""

from __future__ import annotations

import argparse
import json
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BG = "#0b0b0f"
INK, INK2, GRID = "#eeeeee", "#aaaaaa", "#222222"
COLOR = {"moq": "#8ab4ff", "hls": "#ffb74d"}


def run_stats(run: dict, transport: str) -> dict | None:
    vals = [s.get("encoder_to_glass_ms")
            for s in run.get("samples", [])
            if s.get("transport") == transport and s.get("method") == "clock-ocr"]
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    vals.sort()
    p50 = vals[(len(vals) - 1) // 2]
    # OCR misreads slip past the harness's loose plausibility filter; whiskers
    # use only samples within 2.5x of the run median, excluded count reported.
    kept = [v for v in vals if p50 / 2.5 <= v <= p50 * 2.5]
    return {"p50": p50, "min": kept[0], "max": kept[-1], "n": len(kept),
            "outliers": len(vals) - len(kept)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("graph_json", help="mapping file: {\"graph\": {label: notes, …}}")
    ap.add_argument("-o", "--out", default="media-bars.png")
    ap.add_argument("--data", default="site/results/data.json")
    ap.add_argument("--title", default="Latency by media type")
    ap.add_argument("--ymax", type=float, default=None,
                    help="fixed y-axis top in ms; same value across charts keeps the axis identical")
    args = ap.parse_args()

    mapping = json.load(open(args.graph_json))["graph"]
    runs = json.load(open(args.data))["runs"]
    by_notes = {}
    for r in runs:  # later run wins on duplicate notes
        by_notes[r.get("notes", "")] = r

    media, stats = [], {"moq": [], "hls": []}
    for label, notes in mapping.items():
        run = by_notes.get(notes)
        if run is None:
            avail = sorted(n for n in by_notes if n)
            sys.exit(f"no run with notes {notes!r} in {args.data}; available: {avail}")
        media.append(label)
        for t in ("moq", "hls"):
            st = run_stats(run, t)
            if st is None:
                sys.exit(f"run {notes!r} has no clock-ocr {t} samples")
            stats[t].append(st)

    fig, ax = plt.subplots(figsize=(8, 4.5), dpi=200)
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)

    xs = range(len(media))
    width, gap = 0.36, 0.02   # gap keeps a visible seam between the pair
    for i, t in enumerate(("moq", "hls")):
        pos = [x + (i - 0.5) * (width + gap) for x in xs]
        p50 = [s["p50"] for s in stats[t]]
        err = [[s["p50"] - s["min"] for s in stats[t]], [s["max"] - s["p50"] for s in stats[t]]]
        ax.bar(pos, p50, width, color=COLOR[t], label={"moq": "MoQ", "hls": "LL-HLS"}[t],
               yerr=err, error_kw=dict(ecolor=INK2, lw=1.2, capsize=4, capthick=1.2), zorder=3)
        for x, s in zip(pos, stats[t]):
            ax.annotate(f"{s['p50']/1000:.2f}s", (x, s["max"]), xytext=(0, 6),
                        textcoords="offset points", ha="center", color=INK, fontsize=10)

    ax.set_xticks(list(xs), media, color=INK, fontsize=12)
    ax.set_ylabel("encoder-to-glass latency (ms)", color=INK2)
    ax.tick_params(colors=INK2)
    ax.grid(axis="y", color=GRID, lw=0.8, zorder=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    if args.ymax is not None:
        ax.set_ylim(0, args.ymax)
    else:
        ax.margins(y=0.18)
    ax.set_title(args.title, color=INK, fontsize=13, pad=12)
    leg = ax.legend(loc="upper left", frameon=False, labelcolor=INK)
    ns = sorted({s["n"] for t in stats for s in stats[t]})
    dropped = sum(s["outliers"] for t in stats for s in stats[t])
    note = f"bars: per-run clock-ocr medians · whiskers: min–max · n={ns[0]}–{ns[-1]} per bar"
    if dropped:
        note += f" · {dropped} OCR outlier{'s' if dropped > 1 else ''} (>2.5× median) excluded"
    fig.text(0.99, 0.01, note, ha="right", color=INK2, fontsize=7.5)
    fig.tight_layout()
    fig.savefig(args.out, facecolor=BG)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
