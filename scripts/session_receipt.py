#!/usr/bin/env python3
"""Session receipts for the laser-moq publishing stacks.

`up`/`down` in scripts/dev.sh and scripts/prod.sh call this to open/close a
receipt recording config, versions, publisher hardware, endpoint probes, the
ASCII endpoint map, timeline events, and a log excerpt for one session. See
docs/superpowers/specs/2026-09-29-receipts-sessions-design.md for the schema.

Stdlib only. Every collection step is try/excepted; a failed step records
null rather than aborting. Exit code is always 0 unless the JSON files
themselves cannot be written.

Usage:
    python3 scripts/session_receipt.py open --stack {dev,prod} --source {test,capture}
    python3 scripts/session_receipt.py close --stack {dev,prod}
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

JWT_RE = re.compile(r'jwt=[^&\s"]+')


def redact(text: str | None) -> str | None:
    if text is None:
        return None
    return JWT_RE.sub("jwt=<redacted>", text)


def redact_url(url: str | None) -> str | None:
    """Strip the jwt query param entirely (host+path stays, no query leak)."""
    if not url:
        return None
    parsed = urlparse(url)
    kept = [(k, v) for k, v in parse_qsl(parsed.query) if k != "jwt"]
    return urlunparse(parsed._replace(query=urlencode(kept)))


def receipts_dir() -> str:
    d = os.environ.get("RECEIPTS_DIR") or os.path.join(REPO_ROOT, "site", "receipts")
    return d


def run(cmd: list[str], timeout: float = 5.0) -> str | None:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout.strip() or out.stderr.strip() or None
    except Exception:
        return None


def collect_config(stack: str, source: str) -> dict:
    cfg = {"source": source, "size": None, "fps": None, "gop": None,
           "relay": None, "rtmp_host": None, "hls_playlist_url": None,
           "page_url": None, "pins": {}, "mediamtx_tuning": {}}
    try:
        relay_url = os.environ.get("MOQ_RELAY_URL")
        if relay_url:
            parsed = urlparse(relay_url)
            cfg["relay"] = redact_url(f"{parsed.scheme}://{parsed.netloc}{parsed.path}")
    except Exception:
        pass
    try:
        rtmp_url = os.environ.get("RTMP_URL")
        if rtmp_url:
            cfg["rtmp_host"] = urlparse(rtmp_url).hostname
    except Exception:
        pass
    try:
        if stack == "dev":
            cfg["hls_playlist_url"] = "http://localhost:8888/laserdisc/index.m3u8"
            cfg["page_url"] = "http://localhost:8000/"
        else:
            hls_host = os.environ.get("HLS_HOST", "hls-laserdisc.vanessa-dev.com")
            cfg["hls_playlist_url"] = f"https://{hls_host}/laserdisc/index.m3u8"
            cfg["page_url"] = os.environ.get("PAGE_URL", "https://moq-laserdisc.vanessa-dev.com/")
    except Exception:
        pass
    try:
        if source == "capture":
            cfg["size"], cfg["fps"] = os.environ.get("SIZE", "720x480"), os.environ.get("FPS", "60")
        else:
            cfg["size"], cfg["fps"] = os.environ.get("SIZE", "1280x720"), os.environ.get("FPS", "30")
        fps_int = int(float(cfg["fps"]))
        cfg["gop"] = os.environ.get("GOP", str(fps_int // 2))
    except Exception:
        pass
    try:
        index_html = os.path.join(REPO_ROOT, "site", "index.html")
        html = open(index_html).read()
        for name, pattern in (("moq_watch", r"@moq/watch@([\d.]+)"),
                               ("hls_js", r"hls\.js@([\d.]+)"),
                               ("tesseract_js", r"tesseract\.js@([\d.]+)")):
            m = re.search(pattern, html)
            cfg["pins"][name] = m.group(1) if m else None
    except Exception:
        pass
    try:
        mediamtx_yml = os.path.join(REPO_ROOT, "hls-origin", "mediamtx.yml")
        text = open(mediamtx_yml).read()
        for key in ("hlsSegmentDuration", "hlsPartDuration", "hlsSegmentCount", "hlsVariant"):
            m = re.search(rf"^{key}:\s*(\S+)", text, re.MULTILINE)
            cfg["mediamtx_tuning"][key] = m.group(1) if m else None
    except Exception:
        pass
    return cfg


def collect_versions(stack: str) -> dict:
    v = {"moq": None, "ffmpeg": None, "mediamtx": None, "macos": None}
    try:
        v["moq"] = run(["moq", "--version"])
    except Exception:
        pass
    try:
        out = run(["ffmpeg", "-version"])
        v["ffmpeg"] = out.splitlines()[0] if out else None
    except Exception:
        pass
    try:
        compose = "compose.local.yml" if stack == "dev" else "compose.yml"
        text = open(os.path.join(REPO_ROOT, "hls-origin", compose)).read()
        m = re.search(r"image:\s*bluenviron/mediamtx:(\S+)", text)
        v["mediamtx"] = m.group(1) if m else None
    except Exception:
        pass
    try:
        v["macos"] = platform.mac_ver()[0] or None
    except Exception:
        pass
    return v


def collect_publisher_hw() -> dict:
    hw = {"model": None, "cpu": None, "arch": None, "ram_bytes": None,
          "macos_build": None, "uptime": None, "load_avg": None, "thermal_state": None,
          "ffmpeg_cpu_pct": None}
    try:
        hw["model"] = run(["sysctl", "-n", "hw.model"])
    except Exception:
        pass
    try:
        hw["cpu"] = run(["sysctl", "-n", "machdep.cpu.brand_string"])
    except Exception:
        pass
    try:
        hw["arch"] = platform.machine() or None
    except Exception:
        pass
    try:
        ram = run(["sysctl", "-n", "hw.memsize"])
        hw["ram_bytes"] = int(ram) if ram else None
    except Exception:
        pass
    try:
        hw["macos_build"] = run(["sw_vers", "-buildVersion"])
    except Exception:
        pass
    try:
        hw["uptime"] = run(["uptime"])
    except Exception:
        pass
    try:
        hw["load_avg"] = list(os.getloadavg())
    except Exception:
        pass
    try:
        hw["thermal_state"] = run(["pmset", "-g", "therm"])
    except Exception:
        pass
    return hw


def ping_rtt_ms(host: str) -> float | None:
    try:
        out = run(["ping", "-c", "3", host], timeout=8.0)
        if not out:
            return None
        m = re.search(r"= [\d.]+/([\d.]+)/", out)
        return float(m.group(1)) if m else None
    except Exception:
        return None


def http_probe(url: str) -> dict:
    try:
        out = subprocess.run(
            ["curl", "-sS", "-o", "/dev/null", "-D", "-", "--max-time", "5", url],
            capture_output=True, text=True, timeout=8,
        )
        headers = out.stdout.strip()
        status = None
        m = re.search(r"HTTP/\S+\s+(\d+)", headers)
        if m:
            status = int(m.group(1))
        server = None
        m = re.search(r"^[Ss]erver:\s*(.+)$", headers, re.MULTILINE)
        if m:
            server = m.group(1).strip()
        return {"status": status, "server_header": server}
    except Exception:
        return {"status": None, "server_header": None}


def collect_probes(stack: str) -> dict:
    probes = {"relay": None, "hls_origin": None}
    try:
        relay_url = os.environ.get("MOQ_RELAY_URL")
        if relay_url:
            host = urlparse(relay_url).hostname
            if host:
                probes["relay"] = {"ping_avg_ms": ping_rtt_ms(host), **http_probe(f"https://{host}/")}
    except Exception:
        pass
    try:
        if stack == "dev":
            probes["hls_origin"] = {"ping_avg_ms": None,
                                     **http_probe("http://localhost:8888/laserdisc/index.m3u8")}
        else:
            hls_host = os.environ.get("HLS_HOST", "hls-laserdisc.vanessa-dev.com")
            probes["hls_origin"] = {"ping_avg_ms": ping_rtt_ms(hls_host),
                                     **http_probe(f"https://{hls_host}/laserdisc/index.m3u8")}
    except Exception:
        pass
    return probes


def collect_endpoint_map(stack: str) -> str | None:
    try:
        cmd = [sys.executable, os.path.join(HERE, "endpoint_map.py")]
        cmd += ["--hls", "localhost", "--page", "localhost"] if stack == "dev" else []
        out = run(cmd, timeout=15.0)
        return redact(out)
    except Exception:
        return None


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def session_id(started_utc: str, stack: str) -> str:
    dt = datetime.strptime(started_utc, "%Y-%m-%dT%H:%M:%SZ")
    return f"{dt.strftime('%Y%m%d-%H%M%SZ')}-{stack}"


def load_json(path: str, default):
    try:
        return json.load(open(path))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def find_publish_log(stack: str) -> str | None:
    try:
        pattern = os.path.join(REPO_ROOT, "logs", "dev-publish.log" if stack == "dev" else "publish-*.log")
        matches = glob.glob(pattern)
        return max(matches, key=os.path.getmtime) if matches else None
    except Exception:
        return None


def publish_log_mtime(stack: str) -> str | None:
    try:
        newest = find_publish_log(stack)
        if not newest:
            return None
        return datetime.fromtimestamp(os.path.getmtime(newest), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return None


TIMELINE_RE = re.compile(r'^\[(\d{2}:\d{2}:\d{2})\]\s+(start #\d+|exited rc=-?\d+)')
LOG_EXCERPT_RE = re.compile(r'warn|error', re.IGNORECASE)


def parse_log_timeline(log_path: str, started_utc: str) -> list[dict]:
    """publisher start/restart + exit lines from run-forever.sh's log format.
    Log times are local time-of-day; stored converted to UTC."""
    events = []
    try:
        start = datetime.strptime(started_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        local_day = start.astimezone().date()
        with open(log_path, errors="replace") as f:
            for line in f:
                m = TIMELINE_RE.match(line.strip())
                if not m:
                    continue
                detail = m.group(2)
                t = datetime.strptime(m.group(1), "%H:%M:%S").time()
                at = datetime.combine(local_day, t).astimezone().astimezone(timezone.utc)
                if (start - at).total_seconds() > 3600:  # session crossed local midnight
                    at += timedelta(days=1)
                events.append({
                    "at_utc": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "event": "start" if detail.startswith("start") else "exit",
                    "detail": detail,
                })
    except Exception:
        pass
    return events


def parse_log_excerpt(log_path: str) -> list[str]:
    """First + final log line plus up to 40 total warning/error lines."""
    try:
        with open(log_path, errors="replace") as f:
            lines = [l.rstrip("\n") for l in f]
        if not lines:
            return []
        matched = [l for l in lines if LOG_EXCERPT_RE.search(l)]
        bookends = [l for l in (lines[0], lines[-1]) if l not in matched]
        return [redact(l) for l in (bookends + matched)[:40]]
    except Exception:
        return []


def ffmpeg_cpu_pct() -> float | None:
    try:
        out = run(["ps", "-eo", "comm,%cpu"], timeout=3.0)
        if not out:
            return None
        total, found = 0.0, False
        for line in out.splitlines():
            parts = line.rsplit(None, 1)
            if len(parts) == 2 and "ffmpeg" in parts[0]:
                total += float(parts[1])
                found = True
        return total if found else None
    except Exception:
        return None


def scrub(obj):
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, dict):
        return {k: scrub(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub(v) for v in obj]
    return obj


def dirty_sweep(data_path: str, stack: str) -> None:
    """Close any session left open for this stack (crash / missed `down`)."""
    data = load_json(data_path, {"schema": 1, "sessions": []})
    changed = False
    for row in data.get("sessions", []):
        if row.get("stack") == stack and row.get("end") is None:
            ended = publish_log_mtime(stack) or utc_now_iso()
            row["end"] = "dirty"
            row["ended_utc"] = ended
            changed = True
            session_path = os.path.join(receipts_dir(), "sessions", f"{row['id']}.json")
            session = load_json(session_path, None)
            if session is not None:
                session["end"] = "dirty"
                session["ended_utc"] = ended
                session.setdefault("timeline", []).append(
                    {"at_utc": ended, "event": "dirty-close", "detail": "closed by next up"})
                write_json(session_path, session)
    if changed:
        write_json(data_path, data)


def cmd_open(args: argparse.Namespace) -> int:
    rdir = receipts_dir()
    data_path = os.path.join(rdir, "data.json")

    dirty_sweep(data_path, args.stack)

    started_utc = utc_now_iso()
    sid = session_id(started_utc, args.stack)
    # Second-granularity ids: bump start until the id is free.
    while os.path.exists(os.path.join(rdir, "sessions", f"{sid}.json")):
        bumped = datetime.strptime(started_utc, "%Y-%m-%dT%H:%M:%SZ") + timedelta(seconds=1)
        started_utc = bumped.strftime("%Y-%m-%dT%H:%M:%SZ")
        sid = session_id(started_utc, args.stack)

    session = {
        "schema": 1,
        "id": sid,
        "stack": args.stack,
        "source": args.source,
        "started_utc": started_utc,
        "ended_utc": None,
        "end": None,
        "config": collect_config(args.stack, args.source),
        "versions": collect_versions(args.stack),
        "publisher_hw": {"at_open": collect_publisher_hw(), "at_close": None},
        "probes": collect_probes(args.stack),
        "endpoint_map": collect_endpoint_map(args.stack),
        "timeline": [{"at_utc": started_utc, "event": "open", "detail": None}],
        "log_excerpt": [],
        "viewer_note": "remote viewers unknowable; see measure runs in this window",
    }

    session = scrub(session)

    write_json(os.path.join(rdir, "sessions", f"{sid}.json"), session)

    data = load_json(data_path, {"schema": 1, "sessions": []})
    data.setdefault("sessions", []).insert(0, {
        "id": sid,
        "stack": args.stack,
        "source": args.source,
        "started_utc": started_utc,
        "ended_utc": None,
        "end": None,
        "machine": session["publisher_hw"]["at_open"].get("model"),
        "relay_host": (session["config"].get("relay") or "").replace("https://", "").replace("http://", "").split("/")[0] or None,
    })
    write_json(data_path, data)

    print(sid)
    return 0


def cmd_close(args: argparse.Namespace) -> int:
    rdir = receipts_dir()
    data_path = os.path.join(rdir, "data.json")
    data = load_json(data_path, {"schema": 1, "sessions": []})

    row = next((r for r in data.get("sessions", [])
                if r.get("stack") == args.stack and r.get("end") is None), None)
    if row is None:
        print(f"session_receipt: no open session for stack {args.stack}", file=sys.stderr)
        return 0

    session_path = os.path.join(rdir, "sessions", f"{row['id']}.json")
    session = load_json(session_path, None)
    ended_utc = utc_now_iso()

    row["end"] = "clean"
    row["ended_utc"] = ended_utc
    write_json(data_path, data)

    if session is not None:
        session["end"] = "clean"
        session["ended_utc"] = ended_utc
        try:
            at_close = collect_publisher_hw()
            at_close["ffmpeg_cpu_pct"] = ffmpeg_cpu_pct()
        except Exception:
            at_close = collect_publisher_hw()
        session["publisher_hw"]["at_close"] = at_close
        try:
            log_path = find_publish_log(args.stack)
            if log_path:
                session["timeline"].extend(parse_log_timeline(log_path, session.get("started_utc") or ""))
                session["log_excerpt"] = parse_log_excerpt(log_path)
        except Exception:
            pass
        session["timeline"].append({"at_utc": ended_utc, "event": "close", "detail": None})
        session = scrub(session)
        write_json(session_path, session)

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_open = sub.add_parser("open")
    p_open.add_argument("--stack", choices=["prod", "dev"], required=True)
    p_open.add_argument("--source", choices=["test", "capture"], required=True)
    p_open.set_defaults(func=cmd_open)

    p_close = sub.add_parser("close")
    p_close.add_argument("--stack", choices=["prod", "dev"], required=True)
    p_close.set_defaults(func=cmd_close)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
