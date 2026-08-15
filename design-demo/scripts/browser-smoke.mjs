import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
];
const chrome = chromeCandidates.find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for browser smoke tests");

const port = 4300 + (process.pid % 500);
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ["scripts/serve.mjs"], {
  cwd: new URL("../", import.meta.url),
  env: { ...process.env, PORT: String(port) },
  stdio: "ignore"
});

async function waitForServer() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(origin);
      if (response.ok) return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw new Error("design demo server did not become ready");
}

async function dump(pathname) {
  const profile = join(tmpdir(), `changliao-browser-${process.pid}-${Math.random().toString(16).slice(2)}`);
  const { stdout } = await run(chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    `--user-data-dir=${profile}`,
    "--virtual-time-budget=12000",
    "--dump-dom",
    `${origin}${pathname}`
  ], { maxBuffer: 64 * 1024 * 1024, encoding: "utf8" });
  return stdout;
}

try {
  await waitForServer();

  const gallery = await dump("/?module=auth");
  assert.match(gallery, /data-app-ready="true"/u);
  assert.match(gallery, /data-visible-count="24"/u);
  assert.doesNotMatch(gallery, /六合通/u);
  assert.doesNotMatch(gallery, /data-render-error/u);

  const single = await dump("/?screen=wallet-withdrawal-unknown-result");
  assert.match(single, /data-screen-id="wallet-withdrawal-unknown-result"/u);
  assert.match(single, /查询原订单/u);

  const dark = await dump("/?screen=wallet-home-default-dark");
  assert.match(dark, /<html[^>]+data-theme="dark"/u);
  assert.match(dark, /data-screen-id="wallet-home-default-dark"/u);

  const errors = await dump("/?module=wallet&state=error");
  assert.match(errors, /data-visible-count="[1-9][0-9]*"/u);
  assert.doesNotMatch(errors, /data-visible-count="0"/u);

  process.stdout.write("Browser smoke: PASS\n");
} finally {
  server.kill();
}
