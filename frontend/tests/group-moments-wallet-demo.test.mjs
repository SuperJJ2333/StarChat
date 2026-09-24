import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getScreen } from "../src/catalog/screens.js";

const source = async (path) => readFile(new URL(path, import.meta.url), "utf8");

test("group announcement and management states have reviewable demo screens", () => {
  for (const id of [
    "chat-announcement-notice",
    "chat-announcement-dismissed",
    "chat-announcement-editor",
    "chat-announcement-album",
    "chat-group-info-default",
    "chat-group-management-owner",
  ]) assert.equal(getScreen(id).id, id);
});

test("Moments GIF and video selection and playback have demo screens", () => {
  for (const id of [
    "moments-composer-gif",
    "moments-composer-video",
    "moments-media-gif",
    "moments-media-video",
  ]) assert.equal(getScreen(id).id, id);
});

test("announcement color, Moments warning and wallet copy match the requested presentation", async () => {
  const [tokens, styles, moments, wallet, registry] = await Promise.all([
    source("../src/styles/tokens.css"),
    source("../src/styles/primitives.css"),
    source("../src/screens/moments.js"),
    source("../src/screens/wallet-binding.js"),
    source("../../packages/ui-contracts/changliao-component-registry.json"),
  ]);
  assert.match(tokens, /--color-announcement-surface:\s*#fff8e5/u);
  assert.match(styles, /\.c-moments-warning\s*\{/u);
  assert.match(moments, /c-moments-warning/u);
  assert.match(wallet, /仅支持 TRON 网络 · 1 点钻 = 1 CNY · 手续费 0/u);
  assert.ok(JSON.parse(registry).feedbackContracts["2026-09-24-group-moments-wallet-debug"]);
});

test("group name demo limits 12 Unicode graphemes after composition", async () => {
  class TestElement extends EventTarget {
    constructor(tagName) {
      super();
      this.tagName = tagName;
      this.children = [];
      this.dataset = {};
      this.attributes = {};
      this.classList = { add() {} };
      this.maxLength = -1;
      this.value = "";
    }
    append(...children) { this.children.push(...children); }
    setAttribute(name, value) { this.attributes[name] = String(value); }
  }
  const previousDocument = globalThis.document;
  const previousHTMLElement = globalThis.HTMLElement;
  globalThis.HTMLElement = TestElement;
  globalThis.document = { createElement: tag => new TestElement(tag) };
  try {
    const { renderScreen } = await import("../src/screens/messaging.js");
    const descendants = root => [root, ...root.children.flatMap(descendants)];
    const screen = renderScreen(getScreen("chat-group-info-default"));
    const nodes = descendants(screen);
    const input = nodes.find(node => node.className === "c-group-name-row__input");
    const count = nodes.find(node => node.className === "c-group-name-row__count");
    const family = "👨‍👩‍👧‍👦";

    assert.equal(input.maxLength, -1, "native UTF-16 maxlength must not limit graphemes");
    input.value = family.repeat(12);
    input.dispatchEvent(new Event("input"));
    assert.equal(count.textContent, "12/12");

    input.value += "🙂";
    input.dispatchEvent(new Event("input"));
    assert.equal(input.value, family.repeat(12));

    input.dispatchEvent(new Event("compositionstart"));
    input.value += "🙂";
    input.dispatchEvent(new Event("input"));
    assert.equal(input.value, family.repeat(12) + "🙂");
    input.dispatchEvent(new Event("compositionend"));
    assert.equal(input.value, family.repeat(12));
    assert.equal(count.textContent, "12/12");
  } finally {
    globalThis.document = previousDocument;
    globalThis.HTMLElement = previousHTMLElement;
  }
});
