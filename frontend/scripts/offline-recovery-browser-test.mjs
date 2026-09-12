import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const run = promisify(execFile);
const chrome = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
].find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for the offline interaction test");

const port = 4300 + (process.pid % 500);
const origin = `http://127.0.0.1:${port}`;
const browserArtifacts = fileURLToPath(new URL(
  "../../docs/verification/artifacts/2026-09-12/offline-recovery/browser-tests/",
  import.meta.url
));
const server = spawn(process.execPath, ["scripts/serve.mjs"], {
  cwd: new URL("../", import.meta.url),
  env: { ...process.env, PORT: String(port) },
  stdio: "ignore"
});

async function waitForServer() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(origin)).ok) return;
    } catch {
      // The local static server is still starting.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("design demo server did not become ready");
}

try {
  await waitForServer();
  const profile = join(browserArtifacts, `chrome-profile-${process.pid}-${Date.now()}`);
  await mkdir(profile, { recursive: true });
  const { stdout } = await run(chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    `--user-data-dir=${profile}`,
    "--virtual-time-budget=12000",
    "--dump-dom",
    `${origin}/tests/offline-recovery-browser.html`
  ], { maxBuffer: 8 * 1024 * 1024, encoding: "utf8" });
  assert.match(stdout, /data-test-result="passed"/u);
  process.stdout.write("Offline recovery browser interaction: PASS\n");
} finally {
  server.kill();
}
