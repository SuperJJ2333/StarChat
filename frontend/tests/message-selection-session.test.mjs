import test from "node:test";
import assert from "node:assert/strict";

class Node {
  constructor(tag = "div") {
    this.tagName = tag;
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.style = {};
    this.hidden = false;
    this.classList = { add: () => {} };
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  hasAttribute(name) { return name in this.attributes; }
  getAttributeNames() { return Object.keys(this.attributes); }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  removeEventListener(name) { delete this.listeners[name]; }
  getBoundingClientRect() { return { left: 100, top: 100, right: 320, bottom: 180, width: 220, height: 80 }; }
}

globalThis.HTMLElement = Node;
globalThis.document = {
  createElement: tag => new Node(tag),
  createRange: () => ({ setStart() {}, setEnd() {}, selectNodeContents() {}, getBoundingClientRect: () => ({ left: 120, top: 120, right: 220, bottom: 150, width: 100, height: 30 }), getClientRects: () => [{ left: 120, top: 120, right: 180, bottom: 145 }, { left: 120, top: 145, right: 220, bottom: 170 }] })
};
globalThis.window = { addEventListener() {}, removeEventListener() {} };

const { AppEmojiInputDecoration, AppMessageSelectionSession, closestGraphemeBoundary, graphemes } = await import("../src/components/selection.js");
const all = root => [root, ...root.children.filter(child => child instanceof Node).flatMap(all)];

test("emoji decoration displays its supplied text as ordinary demo content", () => {
  const decoration = new AppEmojiInputDecoration();
  decoration.setAttribute("text", "🥲🥲项目更新");
  const rendered = decoration.render();
  assert.equal(rendered.className, "c-emoji-input-decoration");
  assert.equal(rendered.textContent, "🥲🥲项目更新");
});

test("selection session starts as one full-message selection with two large hit targets", () => {
  const session = new AppMessageSelectionSession();
  session.setAttribute("state", "active");
  const rendered = session.render();
  const nodes = all(rendered);
  assert.equal(rendered.dataset.selection, "all");
  assert.equal(nodes.filter(node => node.className === "c-selection-demo__hit").length, 2);
  assert.equal(nodes.filter(node => node.className === "c-selection-demo__handle-line").length, 2);
  assert.equal(nodes.filter(node => node.tagName === "app-anchored-action-menu").length, 1);
  assert.equal(session.selectedText, session.messageText);
});

test("selection menu keeps presentation on a wrapper so the strict menu receives only contract attributes", () => {
  const session = new AppMessageSelectionSession();
  const rendered = session.render();
  const wrapper = all(rendered).find(node => node.className === "c-selection-demo__menu");
  assert.equal(wrapper.tagName, "div");
  const menu = wrapper.children[0];
  assert.equal(menu.tagName, "app-anchored-action-menu");
  assert.equal(menu.className, undefined);
});

test("full selection keeps the original text menu while partial selection adds the compact select-all action", () => {
  const session = new AppMessageSelectionSession();
  const rendered = session.render();
  const menu = all(rendered).find(node => node.tagName === "app-anchored-action-menu");
  assert.deepEqual(JSON.parse(menu.getAttribute("options")).map(option => option.id), ["copy", "forward", "quote", "reminder", "select", "delete"]);
  session.setSelection(2, 9);
  assert.deepEqual(JSON.parse(menu.getAttribute("options")).map(option => option.id), ["copy", "select-all", "quote", "forward"]);
});

test("selection changes re-render the strict menu after its options change", () => {
  const session = new AppMessageSelectionSession();
  session.render();
  let renders = 0;
  session._menuControl.renderContract = () => { renders++; };
  session.setSelection(2, 9);
  assert.equal(renders, 1);
});

test("selection uses grapheme boundaries so an emoji is copied whole", () => {
  const session = new AppMessageSelectionSession();
  assert.deepEqual(graphemes("🥲👨‍👩‍👧‍👦"), ["🥲", "👨‍👩‍👧‍👦"]);
  session.setSelection(2, 9);
  assert.equal(session.selectedText, "上午九点见 🥲");
  assert.equal(session.selectionKind, "partial");
});

test("range-box fallback chooses the nearest grapheme boundary on the touched line", () => {
  const boxes = [
    { start: 0, end: 1, rect: { left: 10, right: 30, top: 10, bottom: 30 } },
    { start: 1, end: 2, rect: { left: 30, right: 50, top: 10, bottom: 30 } },
    { start: 2, end: 3, rect: { left: 10, right: 30, top: 34, bottom: 54 } }
  ];
  assert.equal(closestGraphemeBoundary(boxes, 11, 44), 2);
  assert.equal(closestGraphemeBoundary(boxes, 48, 18), 2);
});

test("selection handles follow the first and last DOM Range rectangles across lines", () => {
  const session = new AppMessageSelectionSession();
  session.render();
  session.setSelection(2, 9);
  assert.match(session._startHandle.style.left, /px$/u);
  assert.match(session._startHandle.style.top, /px$/u);
  assert.match(session._endHandle.style.left, /px$/u);
  assert.match(session._endHandle.style.top, /px$/u);
});

test("menu placement leaves a gap before the selected text instead of covering it", () => {
  const session = new AppMessageSelectionSession();
  session.render();
  assert.match(session._menu.style.top, /px$/u);
  assert.equal(session._menuControl.hasAttribute("arrow-at-top"), false);
});

test("partial actions report and use exactly the selected message text", () => {
  const session = new AppMessageSelectionSession();
  session.setSelection(2, 9);
  assert.equal(session.performAction("quote"), "引用：上午九点见 🥲");
  assert.equal(session.performAction("forward"), "转发：上午九点见 🥲");
  assert.equal(session.performAction("select-all"), "已选择整条消息");
  assert.equal(session.selectedText, session.messageText);
  assert.equal(session.selectionKind, "all");
});

test("copy reports a visible system-copy fallback when clipboard access is unavailable", async () => {
  const session = new AppMessageSelectionSession();
  session.render();
  session.setSelection(2, 9);
  const result = await session.performAction("copy");
  assert.equal(result, "复制不可用，请使用系统复制：上午九点见 🥲");
  assert.equal(session.lastResult, result);
});

test("drag finish and cancellation immediately hide the lens and restore one menu", () => {
  const session = new AppMessageSelectionSession();
  session.beginDrag("end", { clientX: 10, clientY: 10 });
  assert.equal(session.sessionState, "dragging");
  assert.equal(session.lensVisible, true);
  assert.equal(session.menuVisible, false);
  session.finishDrag();
  assert.equal(session.sessionState, "settled");
  assert.equal(session.lensVisible, false);
  assert.equal(session.menuVisible, true);
  session.cancelSession();
  assert.equal(session.sessionState, "dismissed");
  assert.equal(session.lensVisible, false);
  assert.equal(session.menuVisible, false);
});
