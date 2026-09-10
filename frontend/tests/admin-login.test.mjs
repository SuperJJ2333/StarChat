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
