import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { spawn } from "node:child_process";
import { createServer } from "node:net";

const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe", "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe"].find(existsSync);
assert.ok(chrome, "Chrome or Edge is required for the forward browser check");
const artifacts = resolve(process.cwd(), "../docs/verification/artifacts/2026-09-12/media-interactions");
await mkdir(artifacts, { recursive: true });
const profile = await mkdtemp(join(artifacts, "chat-forward-browser-"));
const pageUrl = "http://127.0.0.1:4187/tests/chat-forward-browser.html";

async function unusedPort() {
  const server = createServer();
  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const port = address.port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function waitFor(getValue, description) {
  const deadline = Date.now() + 15000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await getValue();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await wait(50);
  }
  throw new Error(`${description}${lastError ? `: ${lastError.message}` : ""}`);
}

function evaluate(socketUrl, expression) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(socketUrl);
    const id = 1;
    socket.addEventListener("open", () => socket.send(JSON.stringify({ id, method: "Runtime.evaluate", params: { expression, returnByValue: true } })));
    socket.addEventListener("message", event => {
      const response = JSON.parse(event.data);
      if (response.id !== id) return;
      socket.close();
      if (response.error || response.result?.exceptionDetails) {
        reject(new Error(response.error?.message ?? response.result.exceptionDetails.text));
        return;
      }
      resolve(response.result?.result?.value);
    });
    socket.addEventListener("error", () => reject(new Error("DevTools evaluation failed")));
  });
}

function assertArtifactProfile(path) {
  const candidate = resolve(path);
  const remainder = relative(artifacts, candidate);
  assert.ok(remainder && !remainder.startsWith("..") && !isAbsolute(remainder), "refusing to remove a profile outside task artifacts");
  assert.ok(basename(candidate).startsWith("chat-forward-browser-"), "refusing to remove an unexpected artifact directory");
}

const port = await unusedPort();
const browser = spawn(chrome, [
  "--headless=new",
  "--disable-gpu",
  "--no-sandbox",
  "--disable-background-timer-throttling",
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`,
  pageUrl
], { stdio: "ignore" });

let lastState;
try {
  const target = await waitFor(async () => {
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    return pages.find(page => page.type === "page" && page.url.startsWith(pageUrl));
  }, "Chrome did not open the forward browser test");
  const result = await waitFor(async () => {
    const value = await evaluate(target.webSocketDebuggerUrl, "(() => { const page = document.querySelector('#page')?.contentDocument; return { result: document.body.dataset.testResult, message: document.body.dataset.testMessage, innerReady: page?.body?.dataset.appReady, forwardRoot: Boolean(page?.querySelector('[data-demo-source=local-fixture]')) }; })()" );
    lastState = value;
    if (value.result === "failed") throw new Error(value.message ?? "forward browser assertion failed");
    return value.result === "passed" ? value : null;
  }, "forward browser test did not finish");
  assert.equal(result.result, "passed");
  process.stdout.write("Forward background browser interaction: PASS\n");
} catch (error) {
  if (typeof lastState !== "undefined") error.message = `${error.message}; last state: ${JSON.stringify(lastState)}`;
  throw error;
} finally {
  if (browser.exitCode === null) {
    const closed = new Promise(resolve => browser.once("close", resolve));
    browser.kill();
    await closed;
  }
  assertArtifactProfile(profile);
  await rm(profile, { recursive: true, force: true });
}
