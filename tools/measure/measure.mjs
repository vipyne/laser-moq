#!/usr/bin/env node
// OCR latency harness: drives the installed Chrome over the viewer page,
// screenshots each player's clock corner, tesseract-reads the burned-in
// publisher clock, and records glass_to_glass_ms = local clock − burned clock.
// Run on the publisher machine so both clocks are the same clock.
// Only writes site/results/data.json; committing/pushing stays human.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import process from "node:process";

// --- args ---------------------------------------------------------------
const argv = process.argv.slice(2);
const opts = {
  url: "https://moq-laserdisc.vanessa-dev.com/",
  samples: 12,
  intervalMs: 5000,
  source: "test",
  notes: "",
  out: "site/results/data.json",
  debugDir: "",
  headed: false,
  selfTest: false,
  skipPreflight: false,
};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const next = () => argv[++i] ?? die(`missing value for ${a}`);
  if (a === "--url") opts.url = next();
  else if (a === "--samples") opts.samples = Number(next());
  else if (a === "--interval-ms") opts.intervalMs = Number(next());
  else if (a === "--source") opts.source = next();
  else if (a === "--notes") opts.notes = next();
  else if (a === "--out") opts.out = next();
  else if (a === "--debug-dir") opts.debugDir = next();
  else if (a === "--headed") opts.headed = true;
  else if (a === "--self-test") opts.selfTest = true;
  else if (a === "--skip-preflight") opts.skipPreflight = true;
  else die(`unknown flag ${a}`);
}
function die(msg) { console.error(`measure: ${msg}`); process.exit(1); }
const ts = new Date().toISOString().replace(/[-:]/g, "").slice(0, 15);
if (!opts.debugDir) opts.debugDir = path.join("logs", `measure-${ts}`);
fs.mkdirSync(opts.debugDir, { recursive: true });

// --- shared OCR path (self-test exercises exactly this) ------------------
function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.error) die(`${cmd} failed to start: ${r.error.message}`);
  return r;
}
function ocrPng(png) {
  const r = run("tesseract", [png, "stdout", "--psm", "7",
    "-c", "tessedit_char_whitelist=0123456789:."]);
  return r.status === 0 ? r.stdout.trim() : "";
}
function parseClock(text) {
  const m = text.match(/(\d{1,2}):(\d{2}):(\d{2})\.(\d{3})/);
  if (!m) return null;
  const [h, min, s, ms] = m.slice(1).map(Number);
  if (h > 23 || min > 59 || s > 59) return null;
  return ((h * 60 + min) * 60 + s) * 1000 + ms;
}
// OCR the png; if the raw crop doesn't parse, retry on a 2× upscale
// (whitelist stays strict per the plan). Returns {ms, text} or null.
function ocrClock(png) {
  let text = ocrPng(png);
  let ms = parseClock(text);
  if (ms === null) {
    const up = png.replace(/\.png$/, "@2x.png");
    run("ffmpeg", ["-y", "-loglevel", "error", "-i", png,
      "-vf", "scale=iw*2:ih*2:flags=lanczos", up]);
    text = ocrPng(up);
    ms = parseClock(text);
  }
  return ms === null ? null : { ms, text };
}
function cropTopLeft(srcPng, dstPng) {
  // top-left 65% × 30% of the pane — generous because 720x480 capture is
  // pillarboxed inside the 16:9 box and drawtext sits at x=20,y=20 size 48.
  run("ffmpeg", ["-y", "-loglevel", "error", "-i", srcPng,
    "-vf", "crop=iw*0.65:ih*0.30:0:0", dstPng]);
}

// --- self-test: render the repo's drawtext with a literal clock ----------
if (opts.selfTest) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "measure-selftest-"));
  // Same settings as scripts/overlay.filter, literal text. A filter script
  // file, not inline -vf: colons + shell escaping is the known trap.
  fs.writeFileSync(path.join(tmp, "overlay.filter"),
    "drawtext=text='12\\:34\\:56.789':fontsize=48:fontcolor=white:box=1:boxcolor=black@0.6:x=20:y=20\n");
  const frame = path.join(tmp, "frame.png");
  const r = run("ffmpeg", ["-y", "-loglevel", "error",
    "-f", "lavfi", "-i", "color=c=black:s=720x120", "-frames:v", "1",
    "-filter_script:v", path.join(tmp, "overlay.filter"), frame]);
  if (r.status !== 0) die(`self-test render failed:\n${r.stderr}`);
  const got = ocrClock(frame);
  fs.rmSync(tmp, { recursive: true, force: true });
  if (!got || got.text !== "12:34:56.789") {
    die(`self-test OCR mismatch: got '${got ? got.text : "(no parse)"}' want '12:34:56.789'`);
  }
  console.log("self-test ok: parsed 12:34:56.789");
  process.exit(0);
}

// --- live measurement -----------------------------------------------------
// Preflight: fail fast, before Chrome, when the target's streams can't exist.
const pageUrl = new URL(opts.url);
const hlsUrl = pageUrl.searchParams.get("hls")
  ?? "https://hls-laserdisc.vanessa-dev.com/laserdisc/index.m3u8";
async function probe(u) {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 8000);
    const r = await fetch(u, { redirect: "follow", signal: ctl.signal });
    clearTimeout(t);
    return r.status;
  } catch { return 0; }
}
if (!opts.skipPreflight) {
  const pageStatus = await probe(pageUrl);
  if (!pageStatus || pageStatus >= 400)
    die(`preflight: page ${pageUrl} → ${pageStatus || "unreachable"}`);
  const hlsStatus = await probe(hlsUrl);
  if (!hlsStatus || hlsStatus >= 400)
    die(`preflight: HLS playlist ${hlsUrl} → ${hlsStatus || "unreachable"}.\n` +
      `  No stream at that origin — is the publisher's RTMP leg pointed there?\n` +
      `  dev stack: scripts/dev.sh measure · prod: scripts/prod.sh up, then scripts/prod.sh measure`);
}

const { chromium } = await import("playwright");
const localMsOfDay = epochMs => {
  const d = new Date(epochMs);
  return ((d.getHours() * 60 + d.getMinutes()) * 60 + d.getSeconds()) * 1000 + d.getMilliseconds();
};
const DAY = 24 * 60 * 60 * 1000;

const browser = await chromium.launch({ channel: "chrome", headless: !opts.headed });
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
const startedUtc = new Date().toISOString().replace(/\.\d+Z$/, "Z");
console.log(`measure: ${opts.url} samples=${opts.samples} interval=${opts.intervalMs}ms debug=${opts.debugDir}`);
await page.goto(opts.url, { waitUntil: "load" });

// Warm-up: HLS video decoding and MoQ canvas painting non-black, then grace.
const paneState = () => page.evaluate(() => {
  const video = document.getElementById("hls");
  const c = document.querySelector("#moq canvas");
  let moqPainting = false;
  if (c && c.width > 0) {
    try {
      const t = document.createElement("canvas");
      t.width = t.height = 16;
      const ctx = t.getContext("2d");
      ctx.drawImage(c, 0, 0, 16, 16);
      const d = ctx.getImageData(0, 0, 16, 16).data;
      for (let i = 0; i < d.length; i += 4) {
        if (d[i] > 16 || d[i + 1] > 16 || d[i + 2] > 16) { moqPainting = true; break; }
      }
    } catch { /* tainted or no 2d — treat as not painting */ }
  }
  return { hlsReady: !!video && video.readyState >= 2, moqPainting };
});
const WARMUP_MS = 60_000;
let state = { hlsReady: false, moqPainting: false };
for (const t0 = Date.now(); Date.now() - t0 < WARMUP_MS;) {
  state = await paneState();
  if (state.hlsReady && state.moqPainting) break;
  await page.waitForTimeout(1000);
}
if (!state.hlsReady || !state.moqPainting) {
  const dead = [!state.moqPainting && "MoQ canvas never painted", !state.hlsReady && "HLS video never reached readyState 2"]
    .filter(Boolean).join("; ");
  await browser.close();
  die(`warm-up failed: ${dead}\n  page: ${opts.url}\n  hls:  ${hlsUrl}\n` +
    `  (preflight passed, so the origin is up — is the stream flowing? scripts/dev.sh status / scripts/prod.sh status)`);
}
await page.waitForTimeout(15_000); // grace: let both settle to steady-state

// Probe @moq/watch for a latency stat (recorded, not invented — see plan).
const moqProps = await page.evaluate(() =>
  Object.getOwnPropertyNames(Object.getPrototypeOf(document.getElementById("moq"))));
console.log(`moq-watch prototype props: ${moqProps.join(" ")}`);
const moqStats = await page.evaluate(() => {
  const el = document.getElementById("moq");
  const pick = {};
  for (const k of ["latency", "latencyMin", "latencyMax", "jitter"]) {
    try { pick[k] = el[k]; } catch { pick[k] = "(throws)"; }
  }
  return pick;
});
console.log(`moq-watch stats: ${JSON.stringify(moqStats)}`); // recorded, not emitted — schema v1 has no moq api method

// HLS client tuning as actually applied (never hand-typed) — see site/index.html PRESETS.
const tuning = await page.evaluate(() => {
  const h = window.__hls;
  if (!h) return null;
  const cfg = h.config ?? {};
  const det = h.levels?.[h.currentLevel]?.details ?? h.levels?.[0]?.details ?? {};
  const num = v => (typeof v === "number" && Number.isFinite(v) ? v : null);
  return {
    preset: typeof window.__hlspreset === "string" ? window.__hlspreset : null,
    live_sync_s: num(cfg.liveSyncDuration),
    max_latency_s: num(cfg.liveMaxLatencyDuration),
    max_catchup_rate: num(cfg.maxLiveSyncPlaybackRate),
    low_latency: cfg.lowLatencyMode === true,
    part_target_s: num(det.partTarget),
    target_duration_s: num(det.targetduration),
  };
});
console.log(`tuning: ${JSON.stringify(tuning)}`);

const panes = [
  { transport: "moq", selector: "#moq" },
  { transport: "hls", selector: "#hls" },
];
const samples = [];
for (let i = 0; i < opts.samples; i++) {
  for (const { transport, selector } of panes) {
    const el = page.locator(selector);
    const atEpoch = await page.evaluate(() => Date.now()); // immediately before the shot
    const pane = path.join(opts.debugDir, `sample-${String(i).padStart(2, "0")}-${transport}.png`);
    const crop = pane.replace(/\.png$/, "-crop.png");
    try {
      await el.screenshot({ path: pane, timeout: 5000 });
    } catch (e) {
      console.log(`sample ${i} ${transport}: screenshot failed (${e.message.split("\n")[0]})`);
      continue;
    }
    cropTopLeft(pane, crop);
    fs.rmSync(pane, { force: true });
    const atUtc = new Date(atEpoch).toISOString().replace(/\.\d+Z$/, "Z");
    if (transport === "hls") {
      const lat = await page.evaluate(() => window.__hls?.latency);
      if (typeof lat === "number" && Number.isFinite(lat)) {
        samples.push({ transport: "hls", method: "hlsjs-api", latency_ms: Math.round(lat * 1000), at_utc: atUtc });
      }
    }
    const got = ocrClock(crop);
    if (got) {
      const delta = ((localMsOfDay(atEpoch) - got.ms) % DAY + DAY) % DAY;
      // A parsed-but-absurd delta is an OCR misread (a wrong digit can put the
      // burned clock "ahead" of local and wrap mod 24 h). Drop it, keep the crop.
      if (delta > 10 * 60 * 1000) {
        console.log(`sample ${i} ${transport}: implausible delta ${delta}ms from burned=${got.text} — dropped as OCR misread (crop kept: ${crop})`);
        continue;
      }
      samples.push({ transport, method: "clock-ocr", glass_to_glass_ms: delta, at_utc: atUtc });
      console.log(`sample ${i} ${transport}: burned=${got.text} delta=${delta}ms`);
    } else {
      console.log(`sample ${i} ${transport}: OCR parse failed (crop kept: ${crop})`);
    }
  }
  if (i < opts.samples - 1) await page.waitForTimeout(opts.intervalMs);
}

// Endpoint hostnames as the page sees them — used only to look up coarse geo,
// never written anywhere. data.json is committed, so it gets cities and
// coordinates only (tests/test-measure.sh enforces this).
const hosts = await page.evaluate(() => {
  const hostOf = u => { try { return new URL(u, location.href).hostname; } catch { return null; } };
  return {
    relay: hostOf(document.getElementById("moq")?.getAttribute("url") || ""),
    hls: hostOf(window.__hls?.url || document.getElementById("hls")?.currentSrc || ""),
    page: location.hostname,
  };
});
await browser.close();

const geo = await collectGeo(hosts);
console.log(`geo: ${Object.entries(geo).map(([k, g]) => `${k}=${g ? g.city ?? "?" : "-"}`).join(" ")}`);

async function collectGeo(hosts) {
  const ipinfo = async (pathPart) => {
    try {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), 10_000);
      const r = await fetch(`https://ipinfo.io/${pathPart}`, {
        headers: { Accept: "application/json" }, signal: ctl.signal });
      clearTimeout(t);
      return r.ok ? await r.json() : null;
    } catch { return null; }
  };
  const coarse = (g) => {
    if (!g) return null;
    const out = {};
    for (const k of ["city", "region", "country"]) if (g[k]) out[k] = g[k];
    const [lat, lon] = (g.loc || "").split(",").map(Number);
    if (Number.isFinite(lat) && Number.isFinite(lon)) { out.lat = lat; out.lon = lon; }
    return Object.keys(out).length ? out : null;
  };
  const isLocal = h => !h || h === "localhost" || h === "::1" || h.startsWith("127.") || h.endsWith(".local");
  const geoHost = async (host) => {
    if (isLocal(host)) return null;
    try {
      const { lookup } = await import("node:dns/promises");
      const { address } = await lookup(host, { family: 4 });
      return coarse(await ipinfo(`${address}/json`));
    } catch { return null; }
  };
  return {
    publisher: coarse(await ipinfo("json")),
    relay: await geoHost(hosts.relay),
    hls: await geoHost(hosts.hls),
    page: await geoHost(hosts.page),
  };
}

// --- append the run and summarize ----------------------------------------
const target = (() => { const u = new URL(opts.url); u.search = ""; u.hash = ""; return u.toString(); })();
const machine = `${process.arch} ${process.platform === "darwin" ? "mac" : process.platform}`;
const data = JSON.parse(fs.readFileSync(opts.out, "utf8"));
data.runs.push({ started_utc: startedUtc, target, source: opts.source, machine, notes: opts.notes, samples, geo, "tuning": tuning });
fs.writeFileSync(opts.out, JSON.stringify(data, null, 2) + "\n");
console.log(`appended run (${samples.length} samples) to ${opts.out}`);

const p50 = v => v.slice().sort((a, b) => a - b)[Math.floor((v.length - 1) / 2)];
for (const transport of ["moq", "hls"]) {
  const v = samples.filter(s => s.transport === transport && s.method === "clock-ocr")
    .map(s => s.glass_to_glass_ms);
  console.log(v.length
    ? `${transport}: n=${v.length} p50=${p50(v)}ms min=${Math.min(...v)}ms max=${Math.max(...v)}ms`
    : `${transport}: n=0 (no clock-ocr samples parsed)`);
}
