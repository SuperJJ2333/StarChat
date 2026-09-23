import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
import { contractFor } from "../src/catalog/contracts.js";
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
 ["phone-login-phone-error", nodes=> { assert.equal(nodes.filter(n=>n.tag==="input").length,4); assert.ok(nodes.some(n=>n.textContent?.includes("剩余 4"))); }],
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
 globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
 check(walk(await getScreen(id).component()));
});

test("recharge demo advances to payment without claiming credit", async () => {
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
 const root=await getScreen("recharge-directory-directory").component();
 walk(root).find(n=>n.attributes.label==="下一步").handlers.click();
 const nodes=walk(root);
 assert.ok(nodes.some(n=>n.textContent==="客服处理 · 第 2 步"));
 assert.ok(nodes.some(n=>n.textContent?.includes("2 小时")));
 assert.ok(!nodes.some(n=>n.tag==="input"));
 assert.ok(!nodes.some(n=>n.attributes.label==="提交付款凭证"));
 assert.ok(nodes.some(n=>n.attributes["aria-label"]==="保存到本地" && n.attributes.download));
 assert.ok(nodes.some(n=>n.textContent==="收款地址"));
 const copy=nodes.find(n=>n.attributes["aria-label"]==="复制地址");
 assert.equal(copy.tag,"button");
 assert.match(copy.attributes.style,/flex:0 0 48px/);
 assert.ok(copy.children.some(n=>n.dataset.icon==="copy"));
 assert.ok(!nodes.some(n=>n.textContent?.includes("已绑定的钱包")));
});



test("phone OTP validates live and explains consent before send", async () => {
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
 const nodes=walk(await getScreen("phone-login-phone-error").component());
 const phone=nodes.find(n=>n.tag==="input");
 const button=nodes.find(n=>n.attributes.label==="获取验证码");
 for (const node of nodes.filter(n=>n.tag.startsWith('app-'))) {
   const attributes=[...Object.keys(node.attributes), ...Object.keys(node.dataset)
     .map(name=>'data-'+name.replace(/[A-Z]/g, char=>'-'+char.toLowerCase()))];
   const allowed=contractFor(node.tag).allowedAttributes;
   assert.ok(attributes.every(name=>allowed.includes(name)),
     `${node.tag} rejects attributes: ${attributes.filter(name=>!allowed.includes(name)).join(', ')}`);
 }
 assert.equal(button.attributes.disabled,"true");
 // StrictElement does not observe attributes: mounted button state only
 // changes when the page explicitly re-renders the existing component.
 button.renderContract = () => {
   button.renderedDisabled = button.attributes.disabled === 'true';
 };
 button.renderContract();
 phone.value="+86 138 0000 0001";
 phone.handlers.input();
 assert.equal(button.attributes.disabled,undefined);
 assert.equal(button.renderedDisabled,false);
 assert.ok(nodes.some(n=>n.tag==='div' && n.dataset.eligible==='true'));
 button.handlers.click();
 assert.ok(nodes.some(n=>n.textContent==="请先阅读并同意用户协议和隐私政策"));
 phone.value="1380000000x";
 phone.handlers.input();
 assert.equal(button.attributes.disabled,"true");
 assert.equal(button.renderedDisabled,true);
 assert.ok(nodes.some(n=>n.textContent==="邀请码（仅新用户必填）"));
});
