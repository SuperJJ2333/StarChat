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
test("payout 20 points shows minimum and shared toast, then accepts new amount",async()=>{
  globalThis.HTMLElement=class {};
  globalThis.document={createElement:tag=>new Node(tag)};
  const root=await getScreen("wallet-withdrawal-default").component();
  let nodes=walk(root);
  assert.ok(nodes.some(n=>n.textContent?.includes("约需 71.20 点钻")));
  nodes.find(n=>n.textContent==="下一步").handlers.click();
  nodes=walk(root);
  assert.ok(nodes.some(n=>n.tag==="app-toast" && n.attributes.message.includes("最低提现 10 USDT")));
  const amount=nodes.find(n=>n.tag==="input"); amount.value="80.00"; amount.handlers.input();
  nodes.find(n=>n.textContent==="下一步").handlers.click();
  assert.ok(!walk(root).some(n=>n.tag==="app-toast"));
});
