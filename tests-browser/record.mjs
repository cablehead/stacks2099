// Record a running stacks2099 session to video -- a dev/screencast aid (not a test).
//
// Points headless chromium at an already-running server and captures what it
// renders. A real browser, so it speaks every stream the app uses (the page
// load, /sse, and an /pty/view per terminal pane) with no replay harness. The
// terminals are server-rendered DOM text, so headless chromium captures them
// fine -- no GPU or canvas tricks.
//
//   node record.mjs                      # record 20s -> /tmp/stacks2099-cast.mp4
//   node record.mjs --secs 60            # record a fixed 60s
//   node record.mjs --until-enter        # record until you press Enter here
//   node record.mjs /tmp/foo.mp4         # custom output path
//   node record.mjs --master             # also keep a ProRes editing master (.mov)
//   node record.mjs --webm-only          # skip ffmpeg, keep the raw playwright webm
//   BASE=http://127.0.0.1:5300 node record.mjs   # a different instance
//
// Default pipeline: playwright recordVideo (webm/VP8 at 2x scale) -> ffmpeg
// transcode to an H.264 mp4 with 1s keyframes (frame-accurate trims) and
// +faststart. The mp4 is the delivery/editing copy; --master adds an all-intra
// ProRes .mov to re-encode from without loss. The webm is removed after a
// successful transcode unless --webm-only.
//
// ffmpeg must be on PATH for the transcode (brew install ffmpeg). Without it,
// pass --webm-only or install ffmpeg.
import { launchBrowser } from "./lib.mjs";
import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

const BASE = process.env.BASE || "http://127.0.0.1:5099";
const UNTIL_ENTER = flag("--until-enter");
const SECS = Number(opt("--secs", "20"));
const MASTER = flag("--master");
const WEBM_ONLY = flag("--webm-only");
const OUT = args.find((a) => !a.startsWith("--") && !/^\d+$/.test(a)) ||
  process.env.OUT || join(tmpdir(), "stacks2099-cast.mp4");

// 2x device scale + a large recording size keeps text crisp despite
// playwright's ~1 Mbit/s VP8 ceiling (no public bitrate knob).
const VIEWPORT = { width: 1280, height: 800 };
const REC_SIZE = { width: 2560, height: 1600 };

const recDir = mkdtempSync(join(tmpdir(), "stacks2099-rec-"));
const browser = await launchBrowser();
const ctx = await browser.newContext({
  viewport: VIEWPORT,
  deviceScaleFactor: 2,
  recordVideo: { dir: recDir, size: REC_SIZE },
});
const page = await ctx.newPage();
const errors = [];
page.on("console", (m) => {
  if (m.type() === "error") errors.push(m.text());
});

await page.goto(BASE, { waitUntil: "domcontentloaded" });
// Wait for the SSE projection to mount a pane, then let the pty grid stream.
try {
  await page.waitForSelector(".pane", { timeout: 12000 });
} catch { /* record anyway */ }
await page.waitForTimeout(1000);

if (UNTIL_ENTER) {
  console.log(
    `recording ${BASE} -- drive the session, press Enter here to stop`,
  );
  await new Promise((resolve) => {
    process.stdin.resume();
    process.stdin.once("data", () => {
      process.stdin.pause();
      resolve();
    });
  });
} else {
  console.log(`recording ${BASE} for ${SECS}s`);
  await page.waitForTimeout(SECS * 1000);
}

const summary = await page.evaluate(() => ({
  title: document.title,
  panes: document.querySelectorAll(".pane").length,
  clips: document.querySelectorAll("[data-clip]").length,
  hasGrid: !!document.querySelector("[id^='grid-'] *"),
}));
console.log("summary " + JSON.stringify(summary));
if (errors.length) {
  console.log("console_errors " + JSON.stringify(errors.slice(0, 5)));
}

// Closing the context flushes the webm to recDir.
const video = page.video();
await ctx.close();
const webmPath = video ? await video.path() : findWebm(recDir);
await browser.close();

if (WEBM_ONLY) {
  const dest = OUT.replace(/\.mp4$/, ".webm");
  renameSync(webmPath, dest);
  rmSync(recDir, { recursive: true, force: true });
  console.log("cast " + dest);
  process.exit(0);
}

if (!(await hasFfmpeg())) {
  const dest = OUT.replace(/\.mp4$/, ".webm");
  renameSync(webmPath, dest);
  rmSync(recDir, { recursive: true, force: true });
  console.log("ffmpeg not found on PATH -- kept raw recording");
  console.log("cast " + dest);
  process.exit(0);
}

// Delivery: H.264 mp4, 1s keyframes for frame-accurate cuts, faststart.
await run("ffmpeg", [
  "-y",
  "-i",
  webmPath,
  "-c:v",
  "libx264",
  "-crf",
  "18",
  "-preset",
  "slow",
  "-g",
  "30",
  "-keyint_min",
  "30",
  "-sc_threshold",
  "0",
  "-pix_fmt",
  "yuv420p",
  "-movflags",
  "+faststart",
  OUT,
]);
console.log("cast " + OUT);

// Master: all-intra ProRes 4:2:2 10-bit -- every frame a cut point, no chroma
// softening of colored text. Re-encode deliveries from this without loss.
if (MASTER) {
  const masterPath = OUT.replace(/\.mp4$/, ".master.mov");
  await run("ffmpeg", [
    "-y",
    "-i",
    webmPath,
    "-c:v",
    "prores_ks",
    "-profile:v",
    "3",
    "-pix_fmt",
    "yuv422p10le",
    "-r",
    "30",
    "-vsync",
    "cfr",
    masterPath,
  ]);
  console.log("master " + masterPath);
}

rmSync(recDir, { recursive: true, force: true });

function findWebm(dir) {
  const f = readdirSync(dir).find((n) => n.endsWith(".webm"));
  if (!f) throw new Error("no webm produced in " + dir);
  return join(dir, f);
}

function hasFfmpeg() {
  return new Promise((resolve) => {
    const p = spawn("ffmpeg", ["-version"], { stdio: "ignore" });
    p.on("error", () => resolve(false));
    p.on("close", (code) => resolve(code === 0));
  });
}

function run(cmd, argv) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, argv, { stdio: ["ignore", "ignore", "inherit"] });
    p.on("error", reject);
    p.on(
      "close",
      (code) =>
        code === 0 ? resolve() : reject(new Error(`${cmd} exited ${code}`)),
    );
  });
}
