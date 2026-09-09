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
}
globalThis.HTMLElement = Node;
globalThis.document = { createElement: tag => new Node(tag), createElementNS: (_, tag) => new Node(tag) };
const { AppAnchoredActionMenu } = await import("../src/components/anchored-menu.js");
const all = root => [root, ...root.children.flatMap(all)];
test("menu exposes real semantic commands and disabled state", () => {
  const menu = new AppAnchoredActionMenu();
  menu.setAttribute("options", JSON.stringify([{id:"copy",label:"复制"},{id:"delete",label:"删除",disabled:true}]));
  const rendered = menu.render();
  assert.equal(rendered.attributes.role,"menu");
  const buttons = all(rendered).filter(n=>n.tagName==="button");
  assert.equal(buttons.length,2);
  assert.equal(buttons[0].dataset.action,"copy");
  assert.equal(buttons[0].attributes["aria-label"],"复制");
  assert.equal(buttons[1].disabled,true);
  assert.equal(buttons[1].attributes.role,"menuitem");
});
test("top menu and conversation actions reuse the same surface", () => {
  for (const options of [["发起群聊","添加朋友","扫一扫"],["置顶该聊天","标记未读","不显示该聊天","删除该聊天"]]) {
    const menu = new AppAnchoredActionMenu();
    menu.setAttribute("options",JSON.stringify(options.map((label,index)=>({id:String(index),label}))));
    menu.setAttribute("arrow-at-top","true");
    const rendered = menu.render();
    assert.equal(rendered.className,"c-anchored-menu");
    assert.equal(rendered.dataset.arrowAtTop,"true");
    assert.equal(all(rendered).filter(n=>n.tagName==="button").length,options.length);
  }
});
