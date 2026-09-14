import test from "node:test";
import assert from "node:assert/strict";

class Node {
  constructor(tag = "div") { this.tagName = tag; this.children = []; this.dataset = {}; this.attributes = {}; this.listeners = {}; }
  append(...children) { this.children.push(...children); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  hasAttribute(name) { return name in this.attributes; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  dispatchEvent(event) { this.event = event; }
  querySelector(selector) { return all(this, node => node.tagName === selector)[0] ?? null; }
}
globalThis.HTMLElement = Node;
globalThis.document = { createElement: (tag) => new Node(tag) };
const { AppMomentReactions } = await import("../src/components/moments.js");
function all(root, predicate) { return [root, ...root.children.flatMap(child => all(child, predicate))].filter(predicate); }

test("reactions present individual profile controls and comment timestamp", () => {
  const view = new AppMomentReactions();
  view.setAttribute("likes", "林晓、陈默");
  view.setAttribute("comments", "林晓：下次一起走！");
  const root = view.render();
  assert.equal(all(root, n => n.tagName === "app-avatar").length, 3);
  assert.ok(all(root, n => n.dataset.action === "moment:profile:林晓").length >= 2);
  assert.equal(all(root, n => n.tagName === "time").length, 1);
  assert.ok(all(root, n => n.textContent === "下次一起走！").length);
});

test("detail reply state and self comment operations are distinguishable", () => {
  const ownView = new AppMomentReactions();
  ownView.setAttribute("detail", "true");
  ownView.setAttribute("selected", "true");
  ownView.setAttribute("own", "true");
  const root = ownView.render();
  assert.equal(root.dataset.detail, "true");
  assert.ok(all(root, n => n.dataset.selected === "true").length);
  const ownReply = all(root, n => n.tagName === "button" && n.attributes["aria-label"] === "自己的评论，长按复制或删除")[0];
  assert.ok(ownReply);
  assert.equal(ownReply.dataset.action, undefined);
  let stopped = false;
  ownReply.listeners.click({ stopPropagation() { stopped = true; } });
  assert.equal(stopped, true);
  let prevented = false;
  ownReply.listeners.contextmenu({ preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  const menu = all(root, n => n.tagName === "app-anchored-action-menu")[0];
  assert.deepEqual(JSON.parse(menu.attributes.options), [{ id: "copy", label: "复制" }, { id: "delete", label: "删除" }]);

  const replyView = new AppMomentReactions();
  const replyRoot = replyView.render();
  assert.equal(all(replyRoot, n => n.dataset.action === "moment:reply").length, 1);
});
