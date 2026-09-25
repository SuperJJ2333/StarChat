import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { getScreen } from "../src/catalog/screens.js";
import { contractFor } from "../src/catalog/contracts.js";
class Node {
 constructor(tag) { this.tag=tag; this.children=[]; this.dataset={}; this.attributes={}; this.handlers={}; this.classList={add:(name)=>{this.className=[this.className,name].filter(Boolean).join(' ');},toggle(){}}; }
 append(...nodes) { assert.ok(nodes.every(n=>n!==undefined),"undefined child"); this.children.push(...nodes); }
 replaceChildren(...nodes) { this.children=[]; this.append(...nodes); }
 setAttribute(k,v) { this.attributes[k]=v; }
 removeAttribute(k) { delete this.attributes[k]; }
 addEventListener(event, handler) {
   const previous=this.handlers[event];
   this.handlers[event]=previous ? (...args)=>{previous(...args);handler(...args);} : handler;
 }
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



test("phone OTP validates on tap beside the phone field and explains consent", async () => {
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
 const nodes=walk(await getScreen("phone-login-phone-default").component());
 const phone=nodes.find(n=>n.tag==="input");
 const button=nodes.find(n=>n.attributes.label==="获取验证码");
 for (const node of nodes.filter(n=>n.tag.startsWith('app-'))) {
   const attributes=[...Object.keys(node.attributes), ...Object.keys(node.dataset)
     .map(name=>'data-'+name.replace(/[A-Z]/g, char=>'-'+char.toLowerCase()))];
   const allowed=contractFor(node.tag).allowedAttributes;
   assert.ok(attributes.every(name=>allowed.includes(name)),
     `${node.tag} rejects attributes: ${attributes.filter(name=>!allowed.includes(name)).join(', ')}`);
 }
 assert.equal(button.attributes.disabled,undefined);
 // StrictElement does not observe attributes: mounted button state only
 // changes when the page explicitly re-renders the existing component.
 button.renderContract = () => {
   button.renderedDisabled = button.attributes.disabled === 'true';
 };
 button.renderContract();
 button.handlers.click();
 const phoneField=nodes.find(n=>n.className==='c-phone-flows__phone-field');
 const formatError=nodes.find(n=>n.textContent==='请输入中国大陆 11 位手机号');
 assert.ok(formatError);
 assert.ok(phoneField?.children[0].children.includes(phone));
 assert.equal(phoneField.children[1],formatError, 'format error must sit directly under the phone input');
 assert.equal(button.attributes.label,'获取验证码', 'invalid phone must not start cooldown');
 phone.value="+86 138 0000 0001";
 phone.handlers.input();
 assert.equal(button.attributes.disabled,undefined);
 assert.equal(button.renderedDisabled,false);
 assert.ok(nodes.some(n=>n.tag==='div' && n.dataset.eligible==='true'));
 button.handlers.click();
 assert.ok(nodes.some(n=>n.textContent==='手机号格式正确'));
 assert.ok(nodes.some(n=>n.textContent==="请先阅读并同意用户协议和隐私政策"));
 phone.value="1380000000x";
 phone.handlers.input();
 assert.equal(button.attributes.disabled,undefined);
 assert.equal(button.renderedDisabled,false);
 assert.ok(nodes.some(n=>n.textContent==="邀请码（仅新用户必填）"));
});

test("phone OTP and dark auth background expose visible interaction styles", () => {
 const css=readFileSync(new URL('../src/styles/primitives.css', import.meta.url), 'utf8');
 assert.match(css, /\.c-phone-flows__otp-row app-secondary-button \.c-secondary-button\s*\{[^}]*border:[^;]*var\(--color-brand-primary\)/s);
 assert.match(css, /\.c-phone-flows__otp-row app-secondary-button \.c-secondary-button:active:not\(:disabled\)/);
 assert.match(css, /\.ui-screen\[data-theme="dark"\] \.p-auth__background/);
 assert.match(css, /@media \(prefers-reduced-motion: reduce\)[\s\S]*?\.c-phone-flows__otp-row app-secondary-button \.c-secondary-button\s*\{[^}]*transition:\s*none/s);
});

test("phone registration can request a code and reports format below the number", async () => {
 globalThis.HTMLElement=class {};
 globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
 const nodes=walk(await getScreen('phone-registration-phone-default').component());
 const phone=nodes.find(n=>n.tag==='input' && n.placeholder==='+86 手机号');
 const button=nodes.find(n=>n.attributes.label==='获取验证码');
 assert.ok(button, 'registration must expose a code request action');
 assert.equal(button.attributes.disabled,undefined);
 button.handlers.click();
 const phoneField=nodes.find(n=>n.className==='c-phone-flows__phone-field');
 assert.equal(phoneField.children[1].textContent,'请输入中国大陆 11 位手机号');
 assert.equal(button.attributes.label,'获取验证码');
 phone.value='13800000001';
 phone.handlers.input();
 assert.equal(phoneField.children[1].textContent,'手机号格式正确');
});

test("phone auth pages dismiss the keyboard when the page background is tapped", async () => {
 globalThis.HTMLElement=class {};
 let blurred=0;
 globalThis.document={
   createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag),
   activeElement:{blur(){blurred+=1;}}
 };
 for(const id of ['phone-login-phone-default','phone-registration-phone-default']) {
   const page=walk(await getScreen(id).component()).find(n=>n.className?.split(' ').includes('p-auth'));
   assert.equal(typeof page.handlers.pointerdown,'function');
   page.handlers.pointerdown({target:{closest:()=>null}});
   page.handlers.pointerdown({target:{closest:()=>({tagName:'INPUT'})}});
 }
 assert.equal(blurred,2);
});

test("simulated login 429 counts down without re-submitting or rate-limiting OTP", async () => {
 globalThis.HTMLElement=class {};
 const documentHandlers={};
 globalThis.document={
   createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag),
   addEventListener:(name,handler)=>{documentHandlers[name]=handler;},
   removeEventListener:(name)=>{delete documentHandlers[name];}
 };
 const originalSet=globalThis.setInterval;
 const originalClear=globalThis.clearInterval;
 const originalNow=Date.now;
 const ticks=[];
 const cleared=[];
 let now=100000;
 Date.now=()=>now;
 globalThis.setInterval=(callback)=>{ticks.push(callback);return ticks.length;};
 globalThis.clearInterval=(id)=>{cleared.push(id);};
 try {
   const nodes=walk(await getScreen('phone-login-phone-default').component());
   const phone=nodes.find(n=>n.tag==='input' && n.placeholder==='+86 手机号');
   const otp=nodes.find(n=>n.tag==='input' && n.placeholder==='6 位验证码');
   const consent=nodes.find(n=>n.tag==='input' && n.type==='checkbox');
   const button=nodes.find(n=>n.tag==='app-secondary-button');
   const login=nodes.find(n=>n.tag==='app-action-button' && n.attributes.label==='登录');
   phone.value='13800000001';
   otp.value='123456';
   phone.handlers.input();
   consent.checked=true;
   button.handlers.click();
   assert.equal(nodes.some(n=>n.textContent?.includes('登录频繁')),false);
   now+=60000;
   ticks.at(-1)();
   assert.equal(typeof login.handlers.click,'function');
   login.handlers.click();
   const warning=nodes.find(n=>n.textContent?.includes('登录频繁'));
   assert.match(warning.textContent,/演示.*60 秒/);
   assert.equal(login.attributes.disabled,'true');
   now+=30000;
   documentHandlers.visibilitychange();
   assert.match(warning.textContent,/30 秒/);
   now+=29000;
   ticks.at(-1)();
   assert.match(warning.textContent,/1 秒/);
   now+=1000;
   ticks.at(-1)();
   assert.equal(login.attributes.disabled,undefined);
   assert.equal(button.attributes.disabled,undefined);
   assert.equal(warning.textContent,'', 'expiry only permits a new user action');
   assert.ok(cleared.includes(2));
   login.handlers.click();
   login.isConnected=false;
   ticks.at(-1)();
   assert.ok(cleared.includes(3), 'unmount must clear the active countdown timer');
 } finally {
   globalThis.setInterval=originalSet;
   globalThis.clearInterval=originalClear;
   Date.now=originalNow;
 }
});

test('OTP cooldowns use wall-clock deadlines after background throttling', async () => {
 const originalNow=Date.now;
 const originalSet=globalThis.setInterval;
 const originalClear=globalThis.clearInterval;
 let now=100000;
 const callbacks=[];
 const cleared=[];
 Date.now=()=>now;
 globalThis.setInterval=callback=>{callbacks.push(callback);return callbacks.length;};
 globalThis.clearInterval=id=>{cleared.push(id);};
 globalThis.HTMLElement=class {};
 const documentHandlers={};
 globalThis.document={
   createElement:tag=>new Node(tag),createElementNS:(_namespace,tag)=>new Node(tag),
   addEventListener:(name,handler)=>{documentHandlers[name]=handler;},
   removeEventListener:(name)=>{delete documentHandlers[name];}
 };
 try {
   const loginNodes=walk(await getScreen('phone-login-phone-default').component());
   const phone=loginNodes.find(n=>n.tag==='input' && n.placeholder==='+86 手机号');
   const consent=loginNodes.find(n=>n.tag==='input' && n.type==='checkbox');
   const loginOtp=loginNodes.find(n=>n.tag==='app-secondary-button');
   phone.value='13800000001'; phone.handlers.input(); consent.checked=true;
   loginOtp.handlers.click();
   assert.equal(loginOtp.attributes.label,'60 秒后重发');
   now+=30000;
   documentHandlers.visibilitychange();
   assert.equal(loginOtp.attributes.label,'30 秒后重发');
   now+=29000;
   callbacks[0]();
   assert.equal(loginOtp.attributes.label,'1 秒后重发');
   now+=1000;
   callbacks[0]();
   assert.equal(loginOtp.attributes.label,'获取验证码');
   assert.equal(loginOtp.attributes.disabled,undefined);
   assert.ok(cleared.includes(1));

   const registrationNodes=walk(await getScreen('phone-registration-phone-default').component());
   const registrationPhone=registrationNodes.find(n=>n.tag==='input' && n.placeholder==='+86 手机号');
   const registrationOtp=registrationNodes.find(n=>n.tag==='app-secondary-button');
   registrationPhone.value='13800000001'; registrationPhone.handlers.input();
   registrationOtp.handlers.click();
   assert.equal(registrationOtp.attributes.label,'60 秒后重发');
   now+=60000;
   callbacks[1]();
   assert.equal(registrationOtp.attributes.label,'获取验证码');
   assert.equal(registrationOtp.attributes.disabled,undefined);
   assert.ok(cleared.includes(2));

   const initialNodes=walk(await getScreen('phone-login-phone-cooldown').component());
   const initialOtp=initialNodes.find(n=>n.tag==='app-secondary-button');
   assert.equal(initialOtp.attributes.label,'54 秒后重发');
   now+=54000;
   callbacks[2]();
   assert.equal(initialOtp.attributes.label,'获取验证码');
   assert.equal(initialOtp.attributes.disabled,undefined);
   assert.ok(cleared.includes(3));
 } finally {
   Date.now=originalNow;
   globalThis.setInterval=originalSet;
   globalThis.clearInterval=originalClear;
 }
});
