import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";

class TestElement {
  constructor(tagName) {
    this.tagName = tagName;
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.classList = { add() {} };
    this.value = "";
    this.listeners = new Map();
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = [...children]; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(name, callback) {
    this.listeners.set(name, [...(this.listeners.get(name) ?? []), callback]);
  }
  dispatchEvent(event) {
    for (const callback of this.listeners.get(event.type) ?? []) callback(event);
    return true;
  }
}

const descendants = root => [root, ...root.children.flatMap(descendants)];
const byClass = (root, className) => descendants(root).filter(node => node.className?.split(" ").includes(className));

async function withDemoDOM(run) {
  const previousDocument = globalThis.document;
  const previousHTMLElement = globalThis.HTMLElement;
  globalThis.HTMLElement = TestElement;
  globalThis.document = { createElement: tag => new TestElement(tag) };
  try {
    const { renderScreen } = await import("../src/screens/messaging.js");
    return await run(id => renderScreen(getScreen(id)));
  } finally {
    globalThis.document = previousDocument;
    globalThis.HTMLElement = previousHTMLElement;
  }
}

test("search and transfer visual states are registered", () => {
  for (const id of [
    "chat-search-history-results",
    "chat-search-global-results",
    "chat-group-management-transfer-members",
    "chat-group-management-transfer-pending",
    "chat-group-management-transfer-completed",
  ]) assert.equal(getScreen(id).id, id);
});

test("search result and transfer member avatars use 40px slots", async () => {
  await withDemoDOM(render => {
    for (const id of ["chat-search-global-results", "chat-group-management-transfer-members"]) {
      const screen = render(id);
      const slots = byClass(screen, "c-chat-avatar-slot");
      assert.ok(slots.length >= 2, id);
      assert.ok(slots.every(slot => slot.dataset.size === "40"), id);
    }
    const history = render("chat-search-history-results");
    assert.equal(descendants(history).some(node => node.textContent?.includes("部分本地消息尚未解密")), false);
  });
});

test("transfer selection survives filtering and completed view returns to group info", async () => {
  await withDemoDOM(render => {
    const picker = render("chat-group-management-transfer-members");
    const search = byClass(picker, "c-transfer-picker__search")[0];
    assert.ok(search);
    const first = byClass(picker, "c-transfer-picker__member")[0];
    first.dispatchEvent(new Event("click"));
    search.value = "成员乙";
    search.dispatchEvent(new Event("input"));
    search.value = "";
    search.dispatchEvent(new Event("input"));
    assert.equal(byClass(picker, "c-transfer-picker__member")[0].dataset.selected, "true");
    const pending = render("chat-group-management-transfer-pending");
    assert.equal(byClass(pending, "c-transfer-picker__status").length, 1);
    const completed = render("chat-group-management-transfer-completed");
    assert.equal(byClass(completed, "p-chat-group-info__content").length, 1);
    assert.equal(byClass(completed, "c-transfer-picker__status").length, 0);
    assert.equal(byClass(completed, "c-group-transfer-toast").length, 1);
  });
});
