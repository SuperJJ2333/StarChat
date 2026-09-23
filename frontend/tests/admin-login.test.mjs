import test from 'node:test';
import assert from 'node:assert/strict';
import {loginView, sessionExpiredDialog} from '../src/admin-login.js';
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
function setup(api){globalThis.document={createElement:t=>new Element(t),body:new Element('body'),querySelector:()=>null};return loginView(api,()=>{});}
const challenge={challenge_id:'a'.repeat(43),image:'data:image/png;base64,aGVsbG8=',expires_in:120};

test('entry selection is visible and staff login needs neither captcha nor contact OTP',async()=>{
 let calls=0,sent;
 const page=setup({getLoginCaptcha:async()=>{calls++;return challenge;},staffLogin:async body=>{sent=body;return {access_token:'staff-token'};}});
 await settle();
 const entries=['管理员入口','客服入口','首次开通'].map(text=>page.find('button').find(n=>n.textContent===text));
 assert.deepEqual(entries.map(n=>n['aria-pressed']),['true','false','false']);
 await entries[1].handlers.click();await settle();
 assert.equal(calls,1);assert.deepEqual(entries.map(n=>n['aria-pressed']),['false','true','false']);
 assert.equal(page.find('input').find(n=>n.name==='captcha_answer').required,false);
 page.find('input').find(n=>n.name==='username').value='staff';page.find('input').find(n=>n.name==='password').value='test-password';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.deepEqual(sent,{username:'staff',password:'test-password'});
});

test('first activation lets staff select bound email and clears contact choice on submission',async()=>{
 let sent;const page=setup({getLoginCaptcha:async()=>challenge,requestStaffActivation:async body=>{sent=body;return {activation_id:'x'.repeat(43),channel:'email',masked_target:'a***@example.test'};}});
 await settle();await page.find('button').find(n=>n.textContent==='首次开通').handlers.click();
 const channel=page.find('select').find(n=>n.name==='channel');assert.ok(channel);channel.value='email';
 assert.deepEqual(channel.children.map(n=>n.value),['email','phone']);
 page.find('input').find(n=>n.name==='username').value='staff';page.find('input').find(n=>n.name==='password').value='test-password';
 page.find('input').find(n=>n.name==='captcha_answer').value='ABC123';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.equal(sent.channel,'email');assert.equal(sent.email,undefined);assert.equal(sent.phone,undefined);
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

test('staff activation uses server-bound contact then returns to password login',async()=>{
 let sent,confirmed;
 const page=setup({getLoginCaptcha:async()=>challenge,
   requestStaffActivation:async body=>{sent=body;return {activation_id:'z'.repeat(43),channel:'phone',masked_target:'+86****0000',expires_in:300};},
   confirmStaffActivation:async body=>{confirmed=body;return {status:'activated',user_id:'staff'};}});
 await settle();
 const activate=page.find('button').find(n=>n.textContent==='首次开通');
 assert.ok(activate);await activate.handlers.click();await settle();
 page.find('input').find(n=>n.name==='username').value='staff';
 page.find('input').find(n=>n.name==='password').value='secret-password';
 page.find('input').find(n=>n.name==='captcha_answer').value='ABC123';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.equal(sent.username,'staff');assert.equal(sent.phone,undefined);assert.equal(sent.email,undefined);
 assert.ok(page.find('p').some(n=>n.textContent?.includes('+86****0000')));
 const code=page.find('input').find(n=>n.name==='activation_code');code.value='123456';
 await page.find('form')[0].handlers.submit({preventDefault(){}});
 assert.deepEqual(confirmed,{activation_id:'z'.repeat(43),code:'123456'});
 assert.equal(code.value,'');
 assert.ok(page.find('p').some(n=>n.textContent?.includes('开通成功')));
});
