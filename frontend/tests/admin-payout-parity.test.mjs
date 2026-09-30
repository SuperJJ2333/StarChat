import test from 'node:test';
import assert from 'node:assert/strict';

test('withdrawal uses division, six decimal half-up and baseline percentage',async()=>{
  const {previewWithdrawal,adjustReferenceRate}=await import('../src/admin-settlement-preview.js');
  assert.equal(previewWithdrawal('200.00','7.000000'),'28.571429');
  assert.equal(adjustReferenceRate('7.000000',105),'7.350000');
  assert.equal(previewWithdrawal('200.00',adjustReferenceRate('7.000000',105)),'27.210884');
  assert.equal(adjustReferenceRate('7.000000',99),'6.930000');
  assert.equal(adjustReferenceRate('7.000000',95),'6.650000');
  assert.equal(adjustReferenceRate('7.000000',101),'7.070000');
  assert.equal(adjustReferenceRate('7.000000',100),'7.000000');
  assert.equal(previewWithdrawal('9007199254740993.00','1.000000'),'9007199254740993.000000');
  for(const invalid of ['0','-1','1e5','Infinity','1.0000001',''])assert.equal(previewWithdrawal('200.00',invalid),null);
  assert.equal(previewWithdrawal('200.001','7'),null);
  assert.equal(adjustReferenceRate(null,105),null);
});

class Element {
  constructor(tag){this.tag=tag;this.tagName=tag.toUpperCase();this.children=[];this.handlers={};this.attributes={};this.value='';this.textContent='';this.disabled=false;this.dataset={};this.parentNode=null;}
  append(...children){for(const child of children)child.parentNode=this;this.children.push(...children);}
  replaceChildren(...children){for(const child of this.children)child.parentNode=null;this.children=children;for(const child of children)child.parentNode=this;}
  addEventListener(name,fn){this.handlers[name]=fn;}
  setAttribute(name,value){this.attributes[name]=String(value);}
  getAttribute(name){return this.attributes[name]??null;}
  focus(){globalThis.document.activeElement=this;}
  showModal(){this.open=true;this.hidden=false;}
  close(){this.open=false;this.handlers.close?.();}
  querySelectorAll(tag){return this.find(tag);}
  contains(other){for(let node=other;node;node=node.parentNode)if(node===this)return true;return false;}
  find(tag){return [this,...this.children.flatMap(node=>node.find?.(tag)??[])].filter(node=>node.tag===tag);}
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const button=(panel,text)=>panel.find('button').find(node=>node.textContent===text);
const visibleText=panel=>[panel,...panel.children.flatMap(function walk(node){return [node,...node.children.flatMap(walk)];})].map(node=>node.textContent).join(' ');
const future=new Date(Date.now()+300000).toISOString();
const caps=(overrides={})=>({can_claim:false,can_takeover:false,can_begin:false,can_evidence:false,...overrides});


import {supportPayoutPanel} from '../src/admin-support-payout-panel.js';
test('admin withdrawal renders fresh rate, preview and baseline buttons',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};
 const order={id:'admin-1',status:'REQUESTED',funding_asset:'CAIBI',funding_amount:'200.00',final_receive:'28.571429',conversion_rate:'7.000000',prepared_version:0,version:1,claim_version:1,claimed_by:'owner',claim_token:'owner-lease',can_begin:true,can_claim:false,can_evidence:false};
 const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,getFxRate:async()=>({rate:'7.000000',stale:false,fetched_at:new Date().toISOString()})};
 const panel=supportPayoutPanel(api,{actor:{id:'owner'},canOperate:true});await flush();
 button(panel,'处理请求').handlers.click();await flush();
 assert.ok(button(panel,'+5%'));button(panel,'+5%').handlers.click();
 assert.equal(panel.find('input').find(n=>n.placeholder==='确认结算汇率（点钻/USDT）').value,'7.350000');
 assert.match(visibleText(panel),/27.210884/);button(panel,'+5%').handlers.click();
 assert.equal(panel.find('input').find(n=>n.placeholder==='确认结算汇率（点钻/USDT）').value,'7.350000');
 assert.ok(button(panel,'取消提现'));panel.dispose();
});
test('customer service cannot open withdrawal panel or fetch orders',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};let calls=0;
 const panel=supportPayoutPanel({getSupportPayouts:async()=>{calls++;return {items:[]};}},{actor:{id:'staff'},canOperate:false});await flush();
 assert.equal(calls,0);assert.match(visibleText(panel),/仅管理员/);panel.dispose?.();
});
test('unknown no-hash payout exposes verified unbroadcast reversal in same modal',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};
 const order={id:'unknown-1',status:'UNKNOWN',version:2,claim_version:1,execution_started_at:new Date().toISOString(),final_receive:'10.000000',can_evidence:true,claim_token:'lease'};
 const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,getVoidUnbroadcastPreview:async()=>({status:'READY'}),getWalletOperationSecurity:async()=>({auth_mode:'operation_password'})};
 const panel=supportPayoutPanel(api,{actor:{id:'owner'},canOperate:true});await flush();button(panel,'处理请求').handlers.click();await flush();
 assert.ok(button(panel,'确认未广播并撤销'));button(panel,'确认未广播并撤销').handlers.click();await flush();await flush();
 assert.ok(panel.find('input').some(n=>n.type==='checkbox'));
 assert.equal(button(panel,'确认撤销未广播提现').disabled,true);panel.dispose();
});


test('expired unstarted allowed cancellation opens dialog',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};
 const order={id:'expired',status:'REQUESTED',version:1,claim_version:3,can_cancel:true,...caps()};
 const panel=supportPayoutPanel({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order},{actor:{id:'owner'},canOperate:true});await flush();
 const opener=button(panel,'处理请求');assert.ok(opener);assert.equal(opener.disabled,false);
 opener.handlers.click();await flush();assert.ok(button(panel,'取消提现'));panel.dispose();
});


test('refresh preserves unsaved prepayment rate',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};
 const order={id:'draft',status:'REQUESTED',version:1,claim_version:1,can_begin:true,funding_asset:'CAIBI',funding_amount:'200.00',claim_token:'fixture'};
 const panel=supportPayoutPanel({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
 getFxRate:async()=>({rate:'7.000000',stale:false,fetched_at:new Date().toISOString()})},{actor:{id:'owner'},canOperate:true});await flush();
 button(panel,'处理请求').handlers.click();await flush();
 const input=panel.find('input').find(n=>n.placeholder==='确认结算汇率（点钻/USDT）');input.value='7.350000';input.handlers.input();
 await panel.refresh();
 assert.equal(panel.find('input').find(n=>n.placeholder==='确认结算汇率（点钻/USDT）').value,'7.350000');panel.dispose();
});
