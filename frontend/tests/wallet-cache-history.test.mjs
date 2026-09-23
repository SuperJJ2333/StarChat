import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
class Node {
  get lastElementChild() { return this.children.at(-1); }
  constructor(tag) { this.tag=tag; this.children=[]; this.dataset={}; this.attributes={}; this.handlers={}; this.classList={add(){},toggle(){}}; }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children=[]; this.append(...nodes); }
  setAttribute(k,v) { this.attributes[k]=v; }
  addEventListener(event, handler) { this.handlers[event]=handler; }
}
const walk=n=>[n,...n.children.flatMap(walk)];
test("wallet history reuses ledger rows and offline wallet retains content with retry",async()=>{
  globalThis.HTMLElement=class {};
  globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_,tag)=>new Node(tag)};
  const history=await getScreen("wallet-history-all").component();
  assert.ok(walk(history).some(n=>n.className?.includes("c-ledger-row--wallet")));
  const root=await getScreen("wallet-withdrawal-default").component();
  walk(root).find(n=>n.textContent==="模拟离线").handlers.click();
  assert.ok(walk(root).some(n=>n.textContent?.includes("显示上次钱包内容")));
  walk(root).find(n=>n.textContent==="重试更新").handlers.click();
  assert.ok(!walk(root).some(n=>n.textContent?.includes("显示上次钱包内容")));
});