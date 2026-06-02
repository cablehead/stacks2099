// Harness for the browser e2e: spawn an isolated stacks2099 + drive chromium.
//
// Each run uses a fresh temp store on a unique port. The binary defaults to the
// debug build run with --dev (so it serves the live app/ source); override with
// STACKS2099_BIN. Chromium defaults to the system browser; override with
// CHROMIUM_PATH (CI sets it from the installed Chrome).
import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const BIN = process.env.STACKS2099_BIN ||
  join(here, "..", "target", "debug", "stacks2099");
const CHROMIUM = process.env.CHROMIUM_PATH || "/usr/bin/chromium";

let nextPort = 5300 + Math.floor(Math.random() * 300);

// Spawn an isolated server (fresh store, unique port); resolve once it serves.
export async function spawnApp() {
  const port = nextPort++;
  const base = `http://127.0.0.1:${port}`;
  const store = mkdtempSync(join(tmpdir(), "stacks2099-e2e-"));
  const proc = spawn(BIN, ["--dev", `127.0.0.1:${port}`, "--store", store], {
    stdio: "ignore",
  });
  for (let i = 0;; i++) {
    try {
      if ((await fetch(`${base}/`)).ok) break;
    } catch { /* not up yet */ }
    if (i >= 120) {
      proc.kill("SIGKILL");
      throw new Error("stacks2099 did not start");
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return {
    base,
    store,
    close() {
      try {
        proc.kill("SIGTERM");
      } catch { /* gone */ }
      try {
        rmSync(store, { recursive: true, force: true });
      } catch { /* gone */ }
    },
  };
}

export function launchBrowser() {
  return chromium.launch({
    executablePath: CHROMIUM,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
}

// A 1x1 PNG -- enough to assert an image clip loads via /clip/blob.
export const PNG_1x1 = Uint8Array.from(
  atob(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  ),
  (c) => c.charCodeAt(0),
);
