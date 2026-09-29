import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { getScreen } from "../src/catalog/screens.js";

class TestElement extends EventTarget {
  constructor(tagName) {
    super();
    this.tagName = tagName;
    this.className = "";
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.classList = {
      add: (name) => { this.className += ` ${name}`; },
      toggle: () => {},
    };
    this.textContent = "";
  }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = [...nodes]; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
}

const descendants = root => [root, ...root.children.flatMap(descendants)];

test("unbound wallet demo shows the white balance card, binding warning, and read-only history", async () => {
  const previousDocument = globalThis.document;
  const previousHTMLElement = globalThis.HTMLElement;
  globalThis.HTMLElement = TestElement;
  globalThis.document = {
    createElement: tag => new TestElement(tag),
    createElementNS: (_, tag) => new TestElement(tag),
  };
  try {
    const { walletBindingDemo } = await import("../src/screens/wallet-binding.js");
    const screen = walletBindingDemo(getScreen("wallet-home-unbound"));
    const nodes = descendants(screen);
    const hasClass = name => nodes.some(node => node.className.split(/\s+/u).includes(name));
    assert.ok(hasClass("c-wallet-demo__balance-value"));
    assert.ok(hasClass("c-wallet-demo__binding-warning"));
    assert.ok(hasClass("c-wallet-demo__bind-card"));
    const warning = nodes.find(node => node.className === "c-wallet-demo__binding-warning");
    assert.equal(warning.children[0].tagName, "svg");
    assert.equal(warning.children[0].attributes["aria-hidden"], "true");
    assert.equal(warning.children[1].textContent, "请绑定你的钱包地址后再充值、提现。");
    const styles = readFileSync(new URL("../src/styles/primitives.css", import.meta.url), "utf8");
    assert.match(styles, /\.c-wallet-demo__binding-warning\s*\{[^}]*var\(--color-warning\)[^}]*var\(--color-surface-elevated\)/s);
    assert.match(styles, /\.c-wallet-demo__bind-card\s*\{[^}]*var\(--size-touch\)[^}]*var\(--color-surface-elevated\)/s);
    assert.match(styles, /\.c-wallet-demo__balance-value\s*\{[^}]*var\(--type-brand-size\)/s);
    const recharge = nodes.find(node => node.tagName === "button" && node.textContent === "充值");
    const withdrawal = nodes.find(node => node.tagName === "button" && node.textContent === "提现");
    assert.equal(recharge.disabled, true);
    assert.equal(withdrawal.disabled, true);
    const history = nodes.find(node => node.tagName === "button" && node.textContent === "查看已有充值申请");
    assert.ok(history);
    history.dispatchEvent(new Event("click"));
    const after = descendants(screen);
    assert.ok(after.some(node => node.textContent === "示例旧申请 · 只读"));
    assert.equal(after.some(node => node.textContent === "确认充值申请"), false);
  } finally {
    globalThis.document = previousDocument;
    globalThis.HTMLElement = previousHTMLElement;
  }
});

test("bound wallet has no warning and unavailable wallet has no binding entry", async () => {
  const previousDocument = globalThis.document;
  const previousHTMLElement = globalThis.HTMLElement;
  globalThis.HTMLElement = TestElement;
  globalThis.document = {
    createElement: tag => new TestElement(tag),
    createElementNS: (_, tag) => new TestElement(tag),
  };
  try {
    const { walletBindingDemo } = await import("../src/screens/wallet-binding.js");
    const bound = descendants(walletBindingDemo(getScreen("wallet-home-default")));
    assert.equal(bound.some(node => node.className === "c-wallet-demo__binding-warning"), false);
    const unavailable = descendants(walletBindingDemo(getScreen("wallet-home-unavailable")));
    const bind = unavailable.find(node => node.className.includes("c-wallet-demo__bind-card"));
    assert.ok(bind);
    assert.equal(bind.disabled, true);
  } finally {
    globalThis.document = previousDocument;
    globalThis.HTMLElement = previousHTMLElement;
  }
});
