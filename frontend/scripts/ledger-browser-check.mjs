import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { promisify } from "node:util";

const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"].find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for the ledger browser check");

const artifacts = resolve(process.cwd(), "../docs/verification/artifacts/2026-09-12/media-interactions");
await mkdir(artifacts, { recursive: true });
const profile = await mkdtemp(join(artifacts, "ledger-browser-"));

function assertArtifactProfile(path) {
  const candidate = resolve(path);
  const remainder = relative(artifacts, candidate);
  assert.ok(remainder && !remainder.startsWith("..") && !isAbsolute(remainder), "refusing to remove a profile outside task artifacts");
  assert.ok(basename(candidate).startsWith("ledger-browser-"), "refusing to remove an unexpected artifact directory");
}

try {
  const { stdout } = await promisify(execFile)(chrome, [
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--run-all-compositor-stages-before-draw",
    `--user-data-dir=${profile}`,
    "--virtual-time-budget=10000",
    "--dump-dom",
    "http://127.0.0.1:4187/tests/ledger-browser.html"
  ], { encoding: "utf8" });
  assert.match(stdout, /data-test-result="passed"/u, "ledger browser test did not finish successfully");
  process.stdout.write("Ledger browser interaction: PASS\n");
} finally {
  assertArtifactProfile(profile);
  await rm(profile, { recursive: true, force: true });
}
