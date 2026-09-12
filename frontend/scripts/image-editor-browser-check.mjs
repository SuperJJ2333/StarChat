import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const artifactRoot = join(root, "docs", "verification", "artifacts", "2026-09-12", "media-interactions");
const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"].find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for the image editor interaction test");
await mkdir(artifactRoot, { recursive: true });
const profile = await mkdtemp(join(artifactRoot, "image-editor-browser-"));
try {
  const { stdout } = await run(chrome, [
    "--headless=new", "--disable-gpu", "--no-sandbox", `--user-data-dir=${profile}`,
    "--virtual-time-budget=8000", "--dump-dom", "http://127.0.0.1:4187/tests/image-editor-browser.html"
  ], { maxBuffer: 4 * 1024 * 1024, encoding: "utf8", windowsHide: true });
  assert.match(stdout, /data-test-result="passed"/u, "browser interaction test failed");
  process.stdout.write("Image editor browser interaction: PASS\n");
} finally {
  const verifiedRoot = `${resolve(artifactRoot)}\\image-editor-browser-`;
  assert.ok(resolve(profile).startsWith(verifiedRoot), "refusing to delete an unverified browser profile");
  await rm(profile, { recursive: true, force: true });
}
