import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
class Node {
 constructor(tag) { this.tag=tag; this.children=[]; this.dataset={}; this.attributes={}; this.handlers={}; this.classList={add(){},toggle(){}}; }
 append(...nodes) { assert.ok(nodes.every(n=>n!==undefined),"undefined child"); this.children.push(...nodes); }
 replaceChildren(...nodes) { this.children=[]; this.append(...nodes); }
 setAttribute(k,v) { this.attributes[k]=v; }
 removeAttribute(k) { delete this.attributes[k]; }
 addEventListener(event, handler) { this.handlers[event]=handler; }
}
const walk=n=>[n,...n.children.flatMap(walk)];
for (const [id,check] of [
 ["phone-login-phone-error", nodes=> { assert.equal(nodes.filter(n=>n.tag==="input").length,2); assert.ok(nodes.some(n=>n.textContent?.includes("剩余 4"))); }],
 ["phone-registration-phone-matrix-wait",nodes=>assert.ok(nodes.some(n=>n.attributes.disabled==="true"))],
 ["phone-rebind-success",nodes=> { assert.equal(nodes.filter(n=>n.tag==="input").length,0); assert.ok(nodes.some(n=>n.textContent?.includes("手机号已更新"))); }],
 ["transfer-transfer-completed",nodes=>assert.ok(nodes.some(n=>n.textContent==="新群主"))],
 ["wallet-withdrawal-default",nodes=> {
   assert.ok(!nodes.some(n=>n.textContent?.includes("收款钱包")));
   assert.ok(nodes.some(n=>n.attributes.label?.includes("预计到账 USDT · 参考")));
   assert.equal(nodes.find(n=>n.tag==="input").inputMode,"decimal");
 }],
 ["recharge-directory-directory",nodes=> {
   assert.equal(nodes.filter(n=>n.tag==="input").length,1);
   assert.ok(!nodes.some(n=>n.textContent?.includes("客服目录")));
   assert.ok(nodes.some(n=>n.attributes.label?.includes("预计到账")));
   assert.equal(nodes.find(n=>n.tag==="input").inputMode,"decimal");
 }]
]) test(id, async()=>{
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag)};
 check(walk(await getScreen(id).component()));
});

test("recharge demo advances to payment without claiming credit", async () => {
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag)};
 const root=await getScreen("recharge-directory-directory").component();
 walk(root).find(n=>n.attributes.label==="下一步").handlers.click();
 const nodes=walk(root);
 assert.ok(nodes.some(n=>n.textContent==="客服处理 · 第 2 步"));
 assert.ok(nodes.some(n=>n.textContent?.includes("2 小时")));
 const tx=nodes.find(n=>n.tag==="input"); tx.value="a".repeat(64);
 nodes.find(n=>n.attributes.label==="提交付款凭证").handlers.click();
 assert.ok(walk(root).some(n=>n.textContent==="等待到账核验 · 提交凭证不代表到账"));
});

