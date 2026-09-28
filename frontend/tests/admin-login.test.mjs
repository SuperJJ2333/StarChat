import test from 'node:test';
import assert from 'node:assert/strict';
import {loginView, sessionExpiredDialog} from '../src/admin-login.js';
import {showStaffActivationDialog} from '../src/admin-staff-activation-dialog.js';
class Element {
 constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';this.dataset={};}
 append(...nodes){this.children.push(...nodes);}
 setAttribute(k,v){this[k]=v;}
 addEventListener(k,v){this.handlers[k]=v;}
 removeAttribute(k){delete this[k];}
 focus(){this.focused=true;}
 showModal(){this.open=true;}
 close(){this.open=false;this.handlers.close?.();}
 remove(){this.removed=true;}
 find(tag){return [this,...this.children.flatMap(n=>n.find(tag))].filter(n=>n.tag===tag);}
}
const settle=()=>new Promise(r=>setImmediate(r));
function setup(api,onSuccess=()=>{}){globalThis.document={createElement:t=>new Element(t),body:new Element('body'),querySelector:()=>null};return loginView(api,onSuccess);}
const challenge={challenge_id:'a'.repeat(43),image:'data:image/png;base64,aGVsbG8=',expires_in:120};

test('ink-and-silver login presents the four approved poem lines',async()=>{
 const page=setup({getLoginCaptcha:async()=>challenge});await settle();
 const verse=page.find('p').find(item=>item.className==='admin-login-verse');
 assert.equal(verse?.textContent,'赵客缦胡缨，吴钩霜雪明。\n银鞍照白马，飒沓如流星。\n十步杀一人，千里不留行。\n事了拂衣去，深藏身与名。');
 assert.ok(page.find('canvas').some(item=>item['aria-hidden']==='true'));
});

test('one page has only administrator and staff modes; routine staff login needs no captcha',async()=>{
 let calls=0,sent;
 const page=setup({getLoginCaptcha:async()=>{calls++;return challenge;},staffLogin:async body=>{sent=body;return {access_token:'staff-token'};}});
 await settle();
 const entries=['管理员入口','客服入口'].map(text=>page.find('button').find(n=>n.textContent===text));
 assert.equal(page.find('button').filter(n=>n.textContent==='首次开通').length,0);
 assert.deepEqual(entries.map(n=>n['aria-pressed']),['true','false']);
 await entries[1].handlers.click();await settle();
 assert.equal(calls,1);assert.deepEqual(entries.map(n=>n['aria-pressed']),['false','true']);
 assert.equal(page.find('input').find(n=>n.name==='captcha_answer').required,false);
 page.find('input').find(n=>n.name==='username').value='staff';page.find('input').find(n=>n.name==='password').value='test-password';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.deepEqual(sent,{username:'staff',password:'test-password'});
});

test('staff activation is offered only after the precise login response and uses its own captcha',async()=>{
 let loginCalls=0,sent,confirmed,success=0,captchas=0;
 const page=setup({getLoginCaptcha:async()=>{captchas++;return challenge;},staffLogin:async()=>{
   if(++loginCalls===1)throw Object.assign(Error('请先开通'),{code:'STAFF_ACTIVATION_REQUIRED',status:403});
   return {access_token:'staff-token'};
 },requestStaffActivation:async body=>{sent=body;return {activation_id:'x'.repeat(43),channel:'email',masked_target:'a***@example.test',expires_in:300};},
 confirmStaffActivation:async body=>{confirmed=body;return {status:'activated',user_id:'staff'};}},()=>{success++;});
 await settle();await page.find('button').find(n=>n.textContent==='客服入口').handlers.click();
 page.find('input').find(n=>n.name==='username').value='staff';page.find('input').find(n=>n.name==='password').value='test-password';
 await page.find('form')[0].handlers.submit({preventDefault(){}});await settle();
 const dialog=document.body.find('dialog')[0];assert.ok(dialog);assert.equal(dialog['aria-label'],'首次开通验证方式');
 assert.equal(dialog.open,true);assert.equal(captchas,2);
 const channel=dialog.find('select')[0];assert.deepEqual(channel.children.map(n=>n.value),['email','phone']);channel.value='email';
 dialog.find('input').find(n=>n.name==='captcha_answer').value='ABC123';
 await dialog.find('form')[0].handlers.submit({preventDefault(){}});
 assert.equal(sent.username,'staff');assert.equal(sent.password,'test-password');assert.equal(sent.channel,'email');
 assert.equal(sent.challenge_id,challenge.challenge_id);assert.equal(sent.captcha_answer,'ABC123');
 assert.equal(sent.email,undefined);assert.equal(sent.phone,undefined);
 dialog.find('input').find(n=>n.name==='activation_code').value='123456';
 await dialog.find('form')[0].handlers.submit({preventDefault(){}});
 assert.deepEqual(confirmed,{activation_id:'x'.repeat(43),code:'123456'});
 assert.equal(loginCalls,2);assert.equal(success,1);assert.equal(dialog.removed,true);
 assert.equal(page.find('input').find(n=>n.name==='password').value,'');
});

test('a pending administrator captcha response cannot disable the staff form',async()=>{
 let finish;const page=setup({getLoginCaptcha:()=>new Promise(r=>finish=r)});
 await page.find('button').find(n=>n.textContent==='客服入口').handlers.click();
 finish(challenge);await settle();
 assert.equal(page.find('button').find(n=>n.type==='submit').disabled,false);
 assert.equal(page.find('input').find(n=>n.name==='captcha_answer').required,false);
});

test('a late captcha image error cannot disable staff password login',async()=>{
 const page=setup({getLoginCaptcha:async()=>challenge});await settle();
 await page.find('button').find(n=>n.textContent==='客服入口').handlers.click();
 page.find('img').find(n=>n.className==='admin-captcha-image').handlers.error();
 assert.equal(page.find('button').find(n=>n.type==='submit').disabled,false);
});
test('challenge visible, refresh clears stale answer, failed refresh disables login',async()=>{
 let count=0;const page=setup({getLoginCaptcha:async()=>{if(count++)throw Error('offline');return challenge;}});await settle();
 assert.equal(page.find('img').find(n=>n.className==='admin-captcha-image').src,challenge.image);
 const input=page.find('input').find(n=>n.name==='captcha_answer');input.value='ABC123';
 await page.find('button').find(n=>n.textContent==='换一张').handlers.click();
 assert.equal(input.value,'');assert.equal(page.find('button').find(n=>n.type==='submit').disabled,true);
});
test('duplicate submit blocked and secrets cleared; actual error preserved with fresh challenge',async()=>{
 let calls=0,release;const page=setup({getLoginCaptcha:async()=>challenge,adminLogin:async()=>{calls++;await new Promise(r=>release=r);throw Error('账号或密码错误');}});await settle();
 page.find('input').find(n=>n.name==='password').value='synthetic-password';
 const form=page.find('form')[0],event={preventDefault(){}};
 const pending=form.handlers.submit(event);await form.handlers.submit(event);
 assert.equal(calls,1);assert.equal(page.find('input').find(n=>n.name==='password').value,'');
 release();await pending;assert.ok(page.find('p').some(n=>n.textContent?.includes('账号或密码错误')));
});
test('session dialog is modal and re-login only follows explicit action',()=>{
 setup({getLoginCaptcha:async()=>challenge});let calls=0;const dialog=sessionExpiredDialog(()=>calls++);
 assert.equal(dialog.open,true);assert.equal(dialog['aria-labelledby'],'admin-session-title');assert.equal(calls,0);
 dialog.find('button')[0].handlers.click();assert.equal(calls,1);assert.equal(dialog.removed,true);
});

test('other staff denials do not expose activation and mode switch clears the current password',async()=>{
 const page=setup({getLoginCaptcha:async()=>challenge,staffLogin:async()=>{
   throw Object.assign(Error('身份已失效'),{code:'STAFF_ACTIVATION_INVALID',status:403});
 }});
 await settle();await page.find('button').find(n=>n.textContent==='客服入口').handlers.click();
 page.find('input').find(n=>n.name==='password').value='secret-password';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.equal(document.body.find('dialog').length,0);
 assert.equal(page.find('input').find(n=>n.name==='password').value,'');
 page.find('input').find(n=>n.name==='password').value='new-password';
 await page.find('button').find(n=>n.textContent==='管理员入口').handlers.click();
 assert.equal(page.find('input').find(n=>n.name==='password').value,'');
});

test('activation challenge expiry and page leave close the dialog before credentials can be reused',async()=>{
 const original={setTimeout:globalThis.setTimeout,clearTimeout:globalThis.clearTimeout,addEventListener:globalThis.addEventListener,removeEventListener:globalThis.removeEventListener,document:globalThis.document};
 const listeners=new Map(),timers=new Map();let nextTimer=0,confirmationCalls=0;
 globalThis.setTimeout=(fn,ms)=>{const id=++nextTimer;timers.set(id,{fn,ms});return id;};
 globalThis.clearTimeout=id=>timers.delete(id);
 globalThis.addEventListener=(name,fn)=>listeners.set(name,fn);
 globalThis.removeEventListener=name=>listeners.delete(name);
 globalThis.document={createElement:t=>new Element(t),body:new Element('body')};
 const api={getLoginCaptcha:async()=>challenge,requestStaffActivation:async()=>({activation_id:'x'.repeat(43),channel:'email',masked_target:'a***@example.test',expires_in:300}),confirmStaffActivation:async()=>{confirmationCalls++;return {status:'activated'};}};
 try {
   const first=showStaffActivationDialog({api,username:'staff',password:'synthetic',onActivated:()=>{}});
   await settle();first.dialog.find('input').find(n=>n.name==='captcha_answer').value='ABC123';
   await first.dialog.find('form')[0].handlers.submit({preventDefault(){}});
   const expiry=[...timers.values()].find(timer=>timer.ms>0&&timer.ms<=300000);
   assert.ok(expiry,'server challenge lifetime schedules local cleanup');
   expiry.fn();assert.equal(first.dialog.removed,true);
   await first.dialog.find('form')[0].handlers.submit({preventDefault(){}});
   assert.equal(confirmationCalls,0);
   const second=showStaffActivationDialog({api,username:'staff',password:'synthetic',onActivated:()=>{}});
   assert.equal(typeof listeners.get('pagehide'),'function');
   listeners.get('pagehide')();assert.equal(second.dialog.removed,true);
   assert.equal(listeners.has('pagehide'),false);
 } finally {Object.assign(globalThis,original);}
});
