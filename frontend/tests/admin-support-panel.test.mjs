import test from 'node:test';
import assert from 'node:assert/strict';
import { supportPanel } from '../src/admin-support-panel.js';

class Element { constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';this.textContent='';this.disabled=false;this.classList={add(){},toggle(){}};} append(...x){this.children.push(...x)} replaceChildren(...x){this.children=x} setAttribute(){} addEventListener(n,h){this.handlers[n]=h} find(tag){return [this,...this.children.flatMap(x=>x.find?.(tag)??[])].filter(x=>x.tag===tag)} }
const install=()=>globalThis.document={createElement:t=>new Element(t)};
const settle=()=>new Promise(r=>setImmediate(r));

test('support panel sends defaults and amount as a string', async()=>{
  install(); const calls=[];
  const api={getSupportAgents:async()=>({items:[],total:0}),command:async(...args)=>{calls.push(args);return {status:'POSTED',amount:'12.34'}}};
  const panel=supportPanel(api);await settle();
  const forms=panel.find('form');const grant=forms.at(-1);const inputs=grant.find('input');
  inputs[0].value='agent@example.com';inputs[1].value='12.34';grant.handlers.submit({preventDefault(){}});await settle();
  assert.deepEqual(calls[0][1],{user_id:'agent@example.com',amount:'12.34',reason_code:'SUPPORT_CAIBI_GRANT'});
  assert.equal(grant.find('select')[0].value,'');
});

test('support search discards old replies and cancel removal makes no command', async()=>{
  install();let first;const calls=[];
  const api={getSupportAgents:({query})=>query==='old'?new Promise(r=>first=r):Promise.resolve({items:[{id:'new',username:'new',nickname:'新客服',roles:['SUPPORT_AGENT'],badge:'官方客服',dispatch_eligible:true}],total:1}),command:async(...x)=>calls.push(x)};
  const originalConfirm=globalThis.confirm;globalThis.confirm=()=>false;
  const panel=supportPanel(api);await settle();const search=panel.find('input').find(x=>x.placeholder?.includes('搜索'));search.value='old';search.handlers.input();search.value='new';search.handlers.input();await settle();first?.({items:[{id:'old'}],total:1});await settle();
  assert.ok(panel.find('td').some(x=>x.textContent==='new'));
  panel.find('button').find(x=>x.textContent==='移除客服身份')?.handlers.click();
  assert.equal(calls.length,0);globalThis.confirm=originalConfirm;
});

test('support rows select grant targets and edit management values', async()=>{
  install();const agent={id:'agent-1',username:'agent-number',nickname:'客服',roles:['FINANCE_SUPPORT'],badge:'专属客服',dispatch_eligible:true};
  const panel=supportPanel({getSupportAgents:async()=>({items:[agent],total:1}),command:async()=>({})});await settle();
  panel.find('button').find(x=>x.textContent==='选择客服').handlers.click();
  const grant=panel.find('form').at(-1).find('input')[0];assert.equal(grant.value,'agent-1');
  panel.find('button').find(x=>x.textContent==='编辑').handlers.click();
  const manage=panel.find('form')[0].find('input');assert.equal(manage[0].value,'agent-1');assert.equal(manage[1].value,'专属客服');
});

test('grant select writes target and keeps the same key after a failed retry', async()=>{
  install();const keys=[];let fail=true;const api={getSupportAgents:async()=>({items:[{id:'agent',username:'number',nickname:'客服',masked_email:'a***@x.com',dispatch_eligible:true}],total:1}),command:async(_p,_b,o)=>{keys.push(o.idempotencyKey);if(fail)throw Error('network');return {amount:'1.00'}}};
  const panel=supportPanel(api,{mode:'grant'});await settle();const form=panel.find('form')[0],select=form.find('select')[0],inputs=form.find('input');select.value='agent';select.handlers.change();assert.equal(inputs[0].value,'agent');inputs[1].value='1.00';form.handlers.submit({preventDefault(){}});await settle();assert.equal(inputs[0].value,'agent');assert.equal(inputs[1].value,'1.00');fail=false;form.handlers.submit({preventDefault(){}});await settle();assert.equal(keys[0],keys[1]);inputs[0].value='agent';inputs[1].value='2.00';form.handlers.submit({preventDefault(){}});await settle();assert.notEqual(keys[1],keys[2]);
});

test('failed removal keeps the current table and reports an error', async()=>{
  install();globalThis.confirm=()=>true;
  const panel=supportPanel({getSupportAgents:async()=>({items:[{id:'agent',username:'agent',roles:['SUPPORT_AGENT'],badge:'官方客服'}],total:1}),command:async()=>{throw Error('denied')}},{mode:'manage'});
  await settle();panel.find('button').find(x=>x.textContent==='移除客服身份').handlers.click();await settle();
  assert.ok(panel.find('td').some(x=>x.textContent==='agent'));
  assert.ok(panel.find('p').some(x=>x.textContent?.includes('移除失败')));
});

test('pagination requests offset 25 and hides non-dispatchable options', async()=>{
  install();const calls=[];const api={getSupportAgents:async q=>{calls.push(q);return {items:q.offset?[]:[{id:'no',username:'no',dispatch_eligible:false}],total:26}},command:async()=>({})};
  const panel=supportPanel(api,{mode:'grant'});await settle();assert.equal(panel.find('select')[0].find('option').length,1);panel.find('button').find(x=>x.textContent==='下一页').handlers.click();await settle();assert.equal(calls.at(-1).offset,25);assert.equal(panel.find('button').some(x=>x.textContent==='选择客服'),false);
});

test('grant rejects malformed amounts locally without calling the API', async()=>{
  install();const calls=[];const api={getSupportAgents:async()=>({items:[],total:0}),command:async(...a)=>{calls.push(a);return {amount:'1.00'}}};
  const panel=supportPanel(api,{mode:'grant'});await settle();
  const form=panel.find('form')[0],inputs=form.find('input');
  for(const bad of ['abc','1.234','0.00','-5','']){inputs[0].value='agent';inputs[1].value=bad;form.handlers.submit({preventDefault(){}});await settle();assert.equal(calls.length,0,`amount ${bad} must not reach the API`);}
  const feedback=form.find('p').at(-1);
  assert.ok(feedback.className.includes('is-error'));
  assert.ok(feedback.textContent.includes('金额格式无效'));
  assert.equal(feedback.role,'alert');
  inputs[1].value='88.00';form.handlers.submit({preventDefault(){}});await settle();
  assert.equal(calls.length,1);assert.deepEqual(calls[0][1],{user_id:'agent',amount:'88.00',reason_code:'SUPPORT_CAIBI_GRANT'});
});

test('grant failure renders red error feedback with icon and success turns green', async()=>{
  install();let fail=true;const api={getSupportAgents:async()=>({items:[],total:0}),command:async()=>{if(fail)throw Error('点钻储备覆盖不足，发放已被风控阻断，请联系技术核查储备');return {amount:'88.00'}}};
  const panel=supportPanel(api,{mode:'grant'});await settle();
  const form=panel.find('form')[0],inputs=form.find('input');
  inputs[0].value='agent';inputs[1].value='88.00';form.handlers.submit({preventDefault(){}});await settle();
  let feedback=form.find('p').at(-1);
  assert.ok(feedback.className.includes('is-error'));
  assert.ok(feedback.textContent.includes('发放失败'));
  assert.ok(feedback.textContent.includes('储备覆盖不足'));
  assert.ok(feedback.children.some(x=>x.className==='admin-feedback-icon'));
  assert.equal(feedback.role,'alert');
  fail=false;inputs[0].value='agent';inputs[1].value='88.00';form.handlers.submit({preventDefault(){}});await settle();
  feedback=form.find('p').at(-1);
  assert.ok(feedback.className.includes('is-success'));
  assert.ok(feedback.textContent.includes('已发放'));
  assert.ok(feedback.children.some(x=>x.className==='admin-feedback-icon'));
  assert.equal(feedback.role,'status');
});

test('manage form reports failures with error styling too', async()=>{
  install();const api={getSupportAgents:async()=>({items:[],total:0}),command:async()=>{throw Error('权限不足')}};
  const panel=supportPanel(api,{mode:'manage'});await settle();
  const form=panel.find('form')[0],inputs=form.find('input');
  inputs[0].value='u1';inputs[1].value='官方客服';
  form.handlers.submit({preventDefault(){}});await settle();
  const feedback=form.find('p').at(-1);
  assert.ok(feedback.className.includes('is-error'));
  assert.ok(feedback.textContent.includes('保存失败'));
});
