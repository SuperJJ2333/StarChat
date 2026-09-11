import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { spawn, execFile } from "node:child_process";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const artifact = process.env.FINANCE_BROWSER_ARTIFACT_DIR;
assert.ok(artifact, "FINANCE_BROWSER_ARTIFACT_DIR is required so browser profiles stay in verification artifacts");
await mkdir(artifact, { recursive: true });

const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"].find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for the finance browser contract");
const port = 4700 + (process.pid % 200);
const origin = `http://127.0.0.1:${port}`;
const server = spawn(process.execPath, ["scripts/serve.mjs"], { cwd: root, env: { ...process.env, PORT: String(port) }, stdio: "ignore" });

async function waitForServer() {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try { if ((await fetch(`${origin}/tests/finance-chat-browser.html`)).ok) return; } catch {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error("finance browser server did not become ready");
}

async function check(pathname, name) {
  const profile = join(artifact, `browser-profile-${name}`);
  await rm(profile, { recursive: true, force: true });
  await mkdir(profile, { recursive: true });
  const screenshot = join(artifact, `${name}.png`);
  const { stdout, stderr } = await run(chrome, ["--headless=new", "--disable-gpu", "--no-sandbox", `--user-data-dir=${profile}`, "--virtual-time-budget=12000", "--window-size=430,1200", "--dump-dom", `--screenshot=${screenshot}`, `${origin}${pathname}`], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: 20000 });
  const dom = join(artifact, `${name}.dom.html`);
  await writeFile(dom, stdout, "utf8");
  if (stderr) process.stderr.write(stderr);
  assert.match(stdout, /data-test-result="passed"/u, `${name} did not pass`);
  process.stdout.write(`PASS ${name}\nDOM: ${dom}\nSCREENSHOT: ${screenshot}\n`);
}

try {
  await waitForServer();
  await check("/tests/finance-chat-browser.html", "finance-chat-contract");
  await check("/tests/finance-ledger-all-browser.html", "finance-ledger-all");
  await check("/tests/finance-ledger-detail-browser.html", "finance-ledger-detail");
} finally { server.kill(); }
