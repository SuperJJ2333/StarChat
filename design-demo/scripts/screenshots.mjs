import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { screens } from "../src/catalog/screens.js";

const run = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const outputDirectory = join(root, "artifacts", "screenshots");
const chromeCandidates = [
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"
];
const chrome = chromeCandidates.find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for deterministic screenshots");

const port = 4800 + (process.pid % 500);
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ["scripts/serve.mjs"], {
  cwd: root,
  env: { ...process.env, PORT: String(port) },
  stdio: "ignore"
});

async function waitForServer() {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(origin);
      if (response.ok) return;
    } catch {
      await new Promise((resolveReady) => setTimeout(resolveReady, 75));
    }
  }
  throw new Error("design demo server did not become ready");
}

async function prepareOutput() {
  await mkdir(outputDirectory, { recursive: true });
}

async function isValidPng(destination, screen) {
  try {
    const info = await stat(destination);
    if (info.size <= 1000) return false;
    const data = await readFile(destination);
    const hasPngSignature = [137, 80, 78, 71, 13, 10, 26, 10]
      .every((byte, index) => data[index] === byte);
    return hasPngSignature
      && data.readUInt32BE(16) === screen.width
      && data.readUInt32BE(20) === screen.height;
  } catch {
    return false;
  }
}

async function removeVerifiedProfile(profile) {
  const resolvedProfile = resolve(profile);
  const resolvedTemporaryRoot = resolve(tmpdir());
  assert.ok(
    resolvedProfile.startsWith(`${resolvedTemporaryRoot}\\changliao-screenshot-`),
    `refusing to remove unverified profile path: ${resolvedProfile}`
  );
  await rm(resolvedProfile, { recursive: true, force: true });
}

async function capture(screen) {
  const filename = `${screen.id}.png`;
  const destination = join(outputDirectory, filename);
  if (await isValidPng(destination, screen)) return;
  const profile = await mkdtemp(join(tmpdir(), "changliao-screenshot-"));
  const route = `/?screen=${encodeURIComponent(screen.id)}&capture=1`;
  try {
    await run(chrome, [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-sandbox",
      "--force-device-scale-factor=1",
      `--user-data-dir=${profile}`,
      `--window-size=${screen.width},${screen.height}`,
      "--virtual-time-budget=12000",
      `--screenshot=${destination}`,
      `${origin}${route}`
    ], { maxBuffer: 4 * 1024 * 1024, windowsHide: true });
    const info = await stat(destination);
    assert.ok(info.size > 1000, `${filename} is unexpectedly small`);
    const signature = await readFile(destination);
    assert.deepEqual([...signature.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10], `${filename} is not a PNG`);
    assert.equal(signature.readUInt32BE(16), screen.width, `${filename} width must match its registry contract`);
    assert.equal(signature.readUInt32BE(20), screen.height, `${filename} height must match its registry contract`);
  } finally {
    await removeVerifiedProfile(profile);
  }
}

async function mapWithConcurrency(items, concurrency, worker) {
  let cursor = 0;
  const runners = Array.from({ length: concurrency }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      await worker(items[index]);
      if ((index + 1) % 25 === 0 || index + 1 === items.length) {
        process.stdout.write(`Screenshots: ${index + 1}/${items.length}\n`);
      }
    }
  });
  await Promise.all(runners);
}

try {
  await waitForServer();
  await prepareOutput();
  await mapWithConcurrency(screens, 3, capture);
  const generated = (await readdir(outputDirectory)).filter((name) => name.endsWith(".png"));
  assert.equal(generated.length, screens.length, "one screenshot is required for every registered screen");
  process.stdout.write(`Generated ${generated.length} deterministic screen screenshots.\n`);
} finally {
  server.kill();
}
