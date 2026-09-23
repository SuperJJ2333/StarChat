import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getScreen } from "../src/catalog/screens.js";

test("redpacket create keeps only the refund note", async () => {
  const source = await readFile(new URL("../src/screens/finance.js", import.meta.url), "utf8");
  assert.match(source, /未领取的红包，将于24小时后发起退款/u);
  assert.doesNotMatch(source, /正在获取红包限额|红包限额暂未获取|redpacket:retry-limits/u);
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
test("create demo keeps draft editable without static limit hints", async () => {
  globalThis.HTMLElement = class {};
  globalThis.document = { createElement: tag => new DemoNode(tag) };
  const screen = await getScreen("redpacket-create-limits-failed").component();
  const nodes = allNodes(screen);
  const amount = nodes.find(node => node.attributes["aria-label"] === "总金额");
  amount.value = "300.00";
  assert.equal(amount.value, "300.00");
  assert.ok(nodes.some(node => node.textContent === "未领取的红包，将于24小时后发起退款"));
  assert.ok(!nodes.some(node => node.dataset.redpacketLimit));
});
