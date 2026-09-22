import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
class Node {
 constructor(tag) { this.tag=tag; this.children=[]; this.dataset={}; this.attributes={}; this.classList={add(){},toggle(){}}; }
 append(...nodes) { assert.ok(nodes.every(n=>n!==undefined),"undefined child"); this.children.push(...nodes); }
 replaceChildren(...nodes) { this.children=[]; this.append(...nodes); }
 setAttribute(k,v) { this.attributes[k]=v; }
 removeAttribute(k) { delete this.attributes[k]; }
 addEventListener() {}
}
const walk=n=>[n,...n.children.flatMap(walk)];
for (const [id,check] of [
 ["phone-login-phone-error", nodes=> { assert.equal(nodes.filter(n=>n.tag==="input").length,2); assert.ok(nodes.some(n=>n.textContent?.includes("剩余 4"))); }],
 ["phone-registration-phone-matrix-wait",nodes=>assert.ok(nodes.some(n=>n.attributes.disabled==="true"))],
 ["phone-rebind-success",nodes=> { assert.equal(nodes.filter(n=>n.tag==="input").length,0); assert.ok(nodes.some(n=>n.textContent?.includes("手机号已更新"))); }],
 ["transfer-transfer-completed",nodes=>assert.ok(nodes.some(n=>n.textContent==="新群主"))],
 ["recharge-directory-directory",nodes=>assert.equal(nodes.filter(n=>n.tag==="input").length,2)]
]) test(id, async()=>{
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag)};
 check(walk(await getScreen(id).component()));
});

