import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
import { contractFor } from "../src/catalog/contracts.js";

class Node {
  constructor(tag) { this.tag=tag; this.children=[]; this.dataset={}; this.attributes={}; this.handlers={}; this.classList={add(){},toggle(){}}; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  setAttribute(name,value) { this.attributes[name]=String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name,handler) { this.handlers[name]=handler; }
  click() { this.clicked=(this.clicked??0)+1; }
}
const walk = node => [node,...node.children.flatMap(walk)];
function setup() {
  globalThis.HTMLElement=class {};
  globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_ns,tag)=>new Node(tag)};
}
async function render(id) { setup(); return getScreen(id).component(); }
const action = (root,label) => walk(root).find(node=>node.attributes.label===label);
const input = (root,label) => walk(root).find(node=>node.tag==="input" && node.attributes["aria-label"]===label);
function fill(root,label,value) { const field=input(root,label); assert.ok(field,`missing ${label}`); field.value=value; field.handlers.input?.(); }

test("profile has seven ordered actionable values and edit pages have permanent labels",async()=>{
  const nodes=walk(await render("profile-details-default"));
  const rows=nodes.filter(node=>node.tag==="app-list-tile").slice(0,7);
  assert.deepEqual(rows.map(node=>node.attributes.title),["头像","畅聊号","邮箱","手机号","昵称","个性签名","拍一拍"]);
  for(const row of rows) { assert.ok(row.attributes.action); assert.ok(getScreen(row.attributes.action.slice(5))); }
  for(const [screen,label] of [["profile-nickname-default","昵称"],["profile-signature-default","个性签名"]]) assert.ok(walk(await render(screen)).some(node=>node.tag==="app-labeled-input-row" && node.attributes.label===label));
  assert.ok(!nodes.some(node=>/\d+\s*\/\s*(?:12|20|64|140)/u.test(node.textContent??"")));
});

test("settings has account and general groups and retains existing entries",async()=>{
  const nodes=walk(await render("profile-settings-default"));
  for(const text of ["账号","通用"]) assert.ok(nodes.some(node=>node.textContent===text));
  for(const title of ["账号安全","聊天","消息通知","关于畅聊"]) assert.ok(nodes.some(node=>node.attributes.title===title));
});

test("login and account security open the same password catalog renderer",async()=>{
  const login=walk(await render("auth-login-default"));
  const security=walk(await render("account-security-default"));
  assert.equal(login.find(node=>node.attributes.label==="忘记密码").attributes.action,"open:account-password-code");
  assert.equal(security.find(node=>node.attributes.title==="更换密码").attributes.action,"open:account-password-code");
});

test("password demo consumes verification before accepting a new password",async()=>{
  const root=await render("account-password-code");
  fill(root,"已绑定邮箱","demo@example.invalid");
  await action(root,"获取验证码").handlers.click();
  fill(root,"验证码","000000");
  await action(root,"验证并继续").handlers.click();
  assert.ok(walk(root).some(node=>node.attributes.role==="alert"));
  assert.equal(input(root,"新密码"),undefined);
  fill(root,"验证码","246810");
  await action(root,"验证并继续").handlers.click();
  fill(root,"新密码","new-password-123");
  fill(root,"确认密码","different-password");
  await action(root,"确认更换密码").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent?.includes("不一致")));
  fill(root,"确认密码","new-password-123");
  await action(root,"确认更换密码").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent==="密码已更换（演示）"));
  assert.equal(walk(root).filter(node=>node.tag==="input").length,0);
});

test("unbound channel blocks proceeding and anonymous copy avoids binding disclosure",async()=>{
  const blocked=await render("account-password-unbound");
  assert.equal(action(blocked,"验证并继续").attributes.disabled,"true");
  const nodes=walk(await render("account-password-code"));
  assert.ok(nodes.some(node=>node.textContent?.includes("如账号已绑定该验证方式")));
  assert.ok(!nodes.some(node=>node.textContent?.includes("账号不存在")));
});

test("changing OTP target invalidates the previous request",async()=>{
  const root=await render("account-password-code");
  fill(root,"已绑定邮箱","first@example.invalid");
  await action(root,"获取验证码").handlers.click();
  fill(root,"已绑定邮箱","second@example.invalid");
  fill(root,"验证码","246810");
  await action(root,"验证并继续").handlers.click();
  assert.equal(input(root,"新密码"),undefined);
  assert.ok(walk(root).some(node=>node.textContent?.includes("先获取验证码")));
});

test("email rebind proves current channel before requesting new email code",async()=>{
  const root=await render("account-email-old");
  fill(root,"当前验证码","246810");
  await action(root,"验证当前联系方式").handlers.click();
  assert.equal(input(root,"新邮箱"),undefined);
  await action(root,"获取验证码").handlers.click();
  fill(root,"当前验证码","246810");
  await action(root,"验证当前联系方式").handlers.click();
  assert.ok(input(root,"新邮箱"));
  fill(root,"新邮箱","next@example.invalid");
  await action(root,"获取验证码").handlers.click();
  fill(root,"新邮箱验证码","246810");
  await action(root,"保存邮箱").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent==="邮箱已更新（演示）"));
});

test("chat preference failure restores saved setting with visible error",async()=>{
  const root=await render("account-chat-failed");
  const toggle=walk(root).find(node=>node.attributes.role==="switch");
  const before=toggle.attributes["aria-checked"];
  await toggle.handlers.click();
  const after=walk(root).find(node=>node.attributes.role==="switch");
  assert.equal(after.attributes["aria-checked"],before);
  assert.ok(walk(root).some(node=>node.attributes.role==="alert"));
});

test("new custom component attributes obey registered contracts",async()=>{
  for(const id of ["profile-details-edit","account-password-code","account-email-old","account-security-default","account-chat-default"]) {
    for(const node of walk(await render(id)).filter(node=>node.tag.startsWith("app-"))) {
      const allowed=contractFor(node.tag).allowedAttributes;
      assert.ok(Object.keys(node.attributes).every(attribute=>allowed.includes(attribute)),node.tag);
    }
  }
});

test("unbound account links consistently block flows without an existing channel",async()=>{
  const nodes=walk(await render("account-security-unbound"));
  assert.equal(nodes.find(node=>node.attributes.title==="绑定或更换邮箱").attributes.action,"open:account-email-unbound");
  assert.equal(nodes.find(node=>node.attributes.title==="更换密码").attributes.action,"open:account-password-unbound");
});

test("resend cooldown survives changing target and allows a new request after 60 seconds",async()=>{
  const original=Date.now;
  let now=original(); Date.now=()=>now;
  try {
    const root=await render("account-password-code");
    fill(root,"已绑定邮箱","first@example.invalid");
    await action(root,"获取验证码").handlers.click();
    const resend=walk(root).find(node=>node.attributes.label?.includes("秒后可重发"));
    assert.equal(resend.attributes.disabled,"true");
    fill(root,"已绑定邮箱","second@example.invalid");
    now+=60001;
    // Changing channels re-renders without discarding the send cooldown.
    await action(root,"已绑定手机号").handlers.click();
    assert.ok(action(root,"获取验证码"));
  } finally { Date.now=original; }
});

test("expired code cannot produce password proof, including the expired catalog state",async()=>{
  const original=Date.now;
  let now=original(); Date.now=()=>now;
  try {
    const root=await render("account-password-code");
    fill(root,"已绑定邮箱","demo@example.invalid");
    await action(root,"获取验证码").handlers.click();
    now+=300001;
    fill(root,"验证码","246810");
    await action(root,"验证并继续").handlers.click();
    assert.equal(input(root,"新密码"),undefined);
    assert.ok(walk(root).some(node=>node.textContent?.includes("已过期")));
  } finally { Date.now=original; }
});

test("profile edit failure preserves draft, retry updates corresponding right-side value",async()=>{
  const entries=new Map();
  globalThis.localStorage={getItem:key=>entries.get(key)??null,setItem:(key,value)=>entries.set(key,value)};
  try {
    const root=await render("profile-nickname-save-failed");
    for(const node of walk(root).filter(node=>node.tag==="app-labeled-input-row")) node.value="新的演示昵称";
    await action(root,"保存资料").handlers.click();
    assert.ok(walk(root).some(node=>node.attributes.value==="新的演示昵称"));
    assert.equal(entries.size,0);
    await action(root,"保存资料").handlers.click();
    const rows=walk(await render("profile-details-default")).filter(node=>node.tag==="app-list-tile");
    assert.equal(rows.find(node=>node.attributes.title==="昵称").attributes.trailing,"新的演示昵称");
    assert.ok([...entries.values()].every(value=>!value.includes("password")));
  } finally { delete globalThis.localStorage; }
});

test("independent profile demo preserves graphemes and refuses oversized changed values",async()=>{
  const entries=new Map();
  globalThis.localStorage={getItem:key=>entries.get(key)??null,setItem:(key,value)=>entries.set(key,value)};
  try {
    const root=await render("profile-nickname-default");
    const family="👨‍👩‍👧‍👦";
    for(const node of walk(root).filter(node=>node.tag==="app-labeled-input-row")) node.value=family.repeat(13);
    await action(root,"保存资料").handlers.click();
    assert.equal(entries.size,0);
    assert.ok(walk(root).some(node=>node.textContent?.includes("12个字符")));
    for(const node of walk(root).filter(node=>node.tag==="app-labeled-input-row")) node.value=family.repeat(12);
    await action(root,"保存资料").handlers.click();
    assert.equal(JSON.parse([...entries.values()][0]).name,family.repeat(12));
  } finally { delete globalThis.localStorage; }
});

test("username demo rejects invalid and occupied values before confirmation",async()=>{
  const root=await render("profile-username-default");
  fill(root,"新畅聊号","a_1");
  await action(root,"检查并继续").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent?.includes("6–20")));
  fill(root,"新畅聊号","support008");
  await action(root,"检查并继续").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent?.includes("已被使用")));
  fill(root,"新畅聊号","new_user");
  await action(root,"检查并继续").handlers.click();
  assert.ok(action(root,"确认修改畅聊号"));
  await action(root,"确认修改畅聊号").handlers.click();
  assert.ok(walk(root).some(node=>node.textContent?.includes("已修改为 new_user")));
});

test("username demo validates on blur with separate rule sections",async()=>{
  const root=await render("profile-username-default");
  fill(root,"新畅聊号","123abc");
  input(root,"新畅聊号").handlers.blur();
  for(const text of ["请以字母开头","格式规范","修改规则"])
    assert.ok(walk(root).some(node=>node.textContent===text));
});

test("add friend demo uses exact contacts and permits only username final two differences",async()=>{
  const root=await render("contacts-add-default");
  const search=(value)=>{fill(root,"邮箱、畅聊号或手机号",value); action(root,"搜索").handlers.click();};
  search("a111");
  assert.ok(walk(root).some(node=>node.attributes.title==="没有找到用户"));
  search("a11111");
  assert.ok(walk(root).some(node=>node.attributes.trailing==="a1111123"));
  search("a1111144");
  assert.ok(walk(root).some(node=>node.attributes.trailing==="a1111123"));
  for (const value of ["a11111!!", "a11111汉字"]) {
    search(value);
    assert.ok(walk(root).some(node=>node.attributes.title==="没有找到用户"));
  }
  search("friend@example");
  assert.ok(walk(root).some(node=>node.attributes.title==="没有找到用户"));
  search("friend@example.invalid");
  assert.ok(walk(root).some(node=>node.attributes.trailing==="a1111123"));
  search("1380000");
  assert.ok(walk(root).some(node=>node.attributes.title==="没有找到用户"));
  search("13800000001");
  assert.ok(walk(root).some(node=>node.attributes.trailing==="a1111123"));
  for (const value of ["+86 138 0000 0001", "8613800000001"]) {
    search(value);
    assert.ok(walk(root).some(node=>node.attributes.trailing==="a1111123"));
  }
});

test("disabled list actions expose aria-disabled and cannot dispatch navigation",async()=>{
  setup();
  const { AppListTile }=await import("../src/components/identity.js");
  const tile=new AppListTile();
  tile.attr=(name,fallback="")=>({title:"账号安全",action:"open:account-security-default"})[name]??fallback;
  tile.boolAttr=name=>name==="disabled";
  const node=tile.render();
  assert.equal(node.attributes["aria-disabled"],"true");
  assert.equal(node.dataset.action,undefined);
  assert.equal(node.tabIndex,-1);
});

test("enabled list actions respond to Enter and Space keyboard activation",async()=>{
  setup();
  const { AppListTile }=await import("../src/components/identity.js");
  const tile=new AppListTile();
  tile.attr=(name,fallback="")=>({title:"账号安全",action:"open:account-security-default"})[name]??fallback;
  tile.boolAttr=()=>false;
  const node=tile.render();
  let prevented=0;
  for(const key of ["Enter"," "]) node.handlers.keydown({key,preventDefault(){prevented++;}});
  assert.equal(node.clicked,2); assert.equal(prevented,2);
});

test("single-channel security pages lead to the matching ownership proof",async()=>{
  const phone=walk(await render("account-security-phone-only"));
  assert.equal(phone.find(node=>node.attributes.title==="绑定或更换邮箱").attributes.action,"open:account-email-phone");
  const email=walk(await render("account-security-email-only"));
  assert.equal(email.find(node=>node.attributes.title==="绑定或更换手机号").attributes.action,"open:phone-rebind-email");
  const password=walk(await render("account-password-bound-phone"));
  assert.ok(password.some(node=>node.attributes["aria-label"]==="已绑定手机号"));
  assert.ok(!password.some(node=>node.attributes.label==="已绑定邮箱"));
});

test("expired catalog code and expired password proof reject demo code/password",async()=>{
  const expired=await render("account-password-expired");
  fill(expired,"验证码","246810");
  await action(expired,"验证并继续").handlers.click();
  assert.equal(input(expired,"新密码"),undefined);
  const original=Date.now;
  let now=original(); Date.now=()=>now;
  try {
    const root=await render("account-password-password");
    fill(root,"新密码","new-password-123"); fill(root,"确认密码","new-password-123");
    now+=300001; await action(root,"确认更换密码").handlers.click();
    assert.ok(input(root,"验证码")); assert.equal(input(root,"新密码"),undefined);
  } finally { Date.now=original; }
});
