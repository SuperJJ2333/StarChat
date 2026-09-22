import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getScreen } from "../src/catalog/screens.js";

test("redpacket runtime limits register loading and recoverable failure demos", async () => {
  for (const id of ["redpacket-create-limits-loading", "redpacket-create-limits-failed"]) assert.equal(getScreen(id).id, id);
  const source = await readFile(new URL("../src/screens/finance.js", import.meta.url), "utf8");
  assert.match(source, /正在获取红包限额/u);
  assert.match(source, /红包限额暂未获取，以提交时校验为准/u);
  assert.match(source, /redpacket:retry-limits/u);
  assert.doesNotMatch(source, /最高 20000.00 点钻/u);
});

// Minimal DOM harness executes the real screen handler without a browser service.
class DemoNode {
  constructor(tag) { this.tag = tag; this.children = []; this.dataset = {}; this.attributes = {}; this.listeners = {}; this.classList = { add() {} }; }
  append(...nodes) { this.children.push(...nodes); }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(type, handler) { this.listeners[type] = handler; }
  querySelector(selector) { return this.children.find(node => node.tag === selector) ?? this.children.map(node => node.querySelector?.(selector)).find(Boolean); }
}
function allNodes(root) { return [root, ...root.children.flatMap(allNodes)]; }
test("runtime retry handler loads server-shaped cap and preserves draft", async () => {
  globalThis.HTMLElement = class {};
  globalThis.document = { createElement: tag => new DemoNode(tag) };
  const screen = await getScreen("redpacket-create-limits-failed").component();
  const nodes = allNodes(screen);
  const hint = nodes.find(node => node.dataset.redpacketLimit);
  const amount = nodes.find(node => node.attributes["aria-label"] === "总金额");
  const retry = nodes.find(node => node.attributes.action === "redpacket:retry-limits");
  amount.value = "300.00";
  assert.equal(hint.dataset.state, "unavailable");
  retry.listeners.click({ preventDefault() {}, stopPropagation() {} });
  assert.equal(hint.dataset.state, "loading");
  await new Promise(resolve => setTimeout(resolve, 450));
  assert.equal(hint.dataset.state, "ready");
  assert.match(hint.textContent, /500.00 点钻/u);
  assert.equal(amount.value, "300.00");
  assert.equal(nodes.find(node => node.children.includes(retry)).hidden, true);
});
