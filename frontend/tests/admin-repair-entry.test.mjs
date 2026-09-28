import test from 'node:test';
import assert from 'node:assert/strict';
import {walletRepairDialog} from '../src/admin-wallet-repair-dialog.js';
import {manualDepositCaseDialog} from '../src/admin-manual-deposit-case.js';

class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.handlers={}; this.classList={add(){}}; this.style={}; this.value=''; }
  append(...children) { for(const child of children){if(child instanceof Element)child.parent=this;this.children.push(child);} }
  replaceChildren(...children) { for(const child of this.children)if(child instanceof Element)child.parent=null;this.children=[];this.append(...children); }
  setAttribute() {}
  addEventListener(name,handler) { this.handlers[name]=handler; }
  remove() {if(this.parent){this.parent.children=this.parent.children.filter(child=>child!==this);this.parent=null;}}
  focus() {}
  showModal() { this.open=true; }
  close() { this.open=false; this.handlers.close?.(); }
  getBoundingClientRect() { return {left:0,right:1,top:0,bottom:1}; }
  find(tag) { return [this,...this.children.filter(child=>child instanceof Element).flatMap(child=>child.find(tag))].filter(child=>child.tag===tag); }
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const install=()=>globalThis.document={body:new Element('body'),createElement:tag=>new Element(tag)};
const item={txid:'a'.repeat(64),log_index:3,direction:'INFLOW'};
const storage={getItem:()=>null,setItem(){},removeItem(){}};

test('repair preview is a write intent and requires a fresh user submit after verification',async()=>{
  install();let grant=false,prompts=0,previews=0;
  walletRepairDialog({
    getDepositRepairCandidates:async()=>({receipt_id:'receipt-1',items:[{intent_id:'intent-1',username:'alice',expected_amount:'10.000000',network:'TRON'}]}),
    previewWalletRepair:async()=>{previews++;return {blockers:['AMOUNT_MISMATCH']};}
  },item,{actorId:'owner',storage,accessController:{canWrite:()=>grant,requestWriteGrant:async()=>{prompts++;return false;}}});
  await settle();document.body.find('button').find(node=>node.textContent==='选择').handlers.click();
  const form=document.body.find('form')[0];form.find('textarea')[0].value='已核对';
  await form.handlers.submit({preventDefault(){}});assert.equal(prompts,1);assert.equal(previews,0);
  grant=true;await settle();assert.equal(previews,0);
  await form.handlers.submit({preventDefault(){}});assert.equal(previews,1);
});

test('closing wallet repair also removes its detached manual case and sensitive evidence',async()=>{
  install();
  const modal=walletRepairDialog({
    getDepositRepairCandidates:async()=>({receipt_id:'receipt-1',items:[]}),
    getManualDepositCaseContext:async()=>({receipt_id:'receipt-1',user_id:'user-1',username:'alice',amount:'10.000000',cases:[]})
  },item,{actorId:'owner',storage,accessController:{canWrite:()=>true}});
  await settle();
  const openManual=document.body.find('button').find(node=>node.textContent==='超时/无匹配订单：人工补录');
  await openManual.handlers.click();await settle();
  assert.equal(document.body.find('dialog').length,2);
  assert.ok(document.body.find('dd').some(node=>node.textContent==='alice'));
  modal.close();
  assert.equal(document.body.find('dialog').length,0);
  assert.equal(document.body.find('dd').length,0);
});

test('manual deposit case creation is blocked without grant and never auto replayed',async()=>{
  install();let grant=false,prompts=0,creates=0;
  manualDepositCaseDialog({
    getManualDepositCaseContext:async()=>({receipt_id:'receipt-1',user_id:'user-1',cases:[]}),
    createManualDepositCase:async()=>{creates++;return {case_id:'case-1',status:'PENDING'};}
  },item,{actorId:'owner',storage,accessController:{canWrite:()=>grant,requestWriteGrant:async()=>{prompts++;return false;}}});
  await settle();const form=document.body.find('form')[0];
  form.find('textarea')[0].value='归属已核对';form.find('input')[0].checked=true;
  await form.handlers.submit({preventDefault(){}});assert.equal(prompts,1);assert.equal(creates,0);
  grant=true;await settle();assert.equal(creates,0);
  await form.handlers.submit({preventDefault(){}});assert.equal(creates,1);
});

test('expired grant blocks repair execution before journal or API write',async()=>{
  install();let grant=true,prompts=0,executes=0;
  walletRepairDialog({
    getDepositRepairCandidates:async()=>({receipt_id:'receipt-1',items:[{intent_id:'intent-1',username:'alice',expected_amount:'10.000000',network:'TRON'}]}),
    previewWalletRepair:async()=>({preview_id:'preview-1',digest:'digest',expected_version:1,expires_at:'2026-09-13T00:01:30Z',blockers:[],confirmation:{amount:'10.000000'}}),
    executeWalletRepair:async()=>{executes++;return {status:'EXECUTED'};}
  },item,{actorId:'owner',storage,accessController:{canWrite:()=>grant,requestWriteGrant:async()=>{prompts++;return false;}}});
  await settle();document.body.find('button').find(node=>node.textContent==='选择').handlers.click();
  const form=document.body.find('form')[0];form.find('textarea')[0].value='已核对';await form.handlers.submit({preventDefault(){}});
  const check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;check.handlers.change();
  const execute=document.body.find('button').find(node=>node.textContent==='确认补入账');
  grant=false;await execute.handlers.click();assert.equal(prompts,1);assert.equal(executes,0);
  grant=true;await settle();assert.equal(executes,0);
  await execute.handlers.click();assert.equal(executes,1);
});

test('manual case decision preview and execution each require a live grant',async()=>{
  install();const saved=new Map([[`chatflow.manual.deposit-case:owner:${item.txid}:3`,JSON.stringify({case_id:'case-1'})]]);
  let grant=false,prompts=0,decisions=0,previews=0,executes=0;
  manualDepositCaseDialog({
    getManualDepositCase:async()=>({case_id:'case-1',status:'PENDING',user_id:'user-1'}),
    decideManualDepositCase:async()=>{decisions++;return {case_id:'case-1',status:'APPROVED',user_id:'user-1'};},
    previewManualDepositCase:async()=>{previews++;return {status:'VALIDATED',blockers:[],preview_id:'preview-1',digest:'digest',expected_version:1,expires_at:'2026-09-13T00:01:30Z'};},
    executeManualDepositCase:async()=>{executes++;return {status:'EXECUTED'};}
  },item,{actorId:'owner',storage:{getItem:key=>saved.get(key)??null,setItem:(key,value)=>saved.set(key,value),removeItem:key=>saved.delete(key)},
    accessController:{canWrite:()=>grant,requestWriteGrant:async()=>{prompts++;return false;}}});
  await settle();const detail=document.body.find('textarea')[0],confirm=document.body.find('input')[0];detail.value='已核对';confirm.checked=true;
  const approve=document.body.find('button').find(node=>node.textContent==='批准补录单');
  await approve.handlers.click();assert.equal(prompts,1);assert.equal(decisions,0);
  grant=true;await approve.handlers.click();assert.equal(decisions,1);
  const preview=document.body.find('button').find(node=>node.textContent==='预检（不入账）');
  grant=false;await preview.handlers.click();assert.equal(prompts,2);assert.equal(previews,0);
  grant=true;await preview.handlers.click();await settle();assert.equal(previews,1);
  const check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;check.handlers.change();
  const execute=document.body.find('button').find(node=>node.textContent==='确认入账');
  grant=false;await execute.handlers.click();assert.equal(prompts,3);assert.equal(executes,0);
  grant=true;await execute.handlers.click();assert.equal(executes,1);
});

test('deposit repair keeps a visible disabled confirmation and manual entry before and after a blocked preview',async()=>{
  install(); let execute=0;
  walletRepairDialog({
    getDepositRepairCandidates:async()=>({receipt_id:'receipt-1',items:[{intent_id:'intent-1',username:'alice',nickname:'Alice',expected_amount:'10.000000',network:'TRON',intent_status:'EXPIRED'}]}),
    previewWalletRepair:async()=>({blockers:['AMOUNT_MISMATCH'],confirmation:{intent_id:'intent-1',username:'alice',amount:'9.000000'}}),
    executeWalletRepair:async()=>{execute++;}
  },item,{actorId:'owner',storage});
  await settle(); await settle();
  assert.ok(document.body.find('button').some(node=>node.textContent==='超时/无匹配订单：人工补录'));
  document.body.find('button').find(node=>node.textContent==='选择').handlers.click();
  assert.equal(document.body.find('button').find(node=>node.textContent==='确认补入账').disabled,true);
  assert.ok(document.body.find('button').some(node=>node.textContent==='超时/无匹配订单：人工补录'));
  const form=document.body.find('form')[0]; form.find('textarea')[0].value='金额差异已核对'; form.handlers.submit({preventDefault(){}});
  await settle(); await settle();
  const confirm=document.body.find('button').find(node=>node.textContent==='确认补入账');
  assert.equal(confirm.disabled,true);
  assert.ok(document.body.find('p').some(node=>node.textContent?.includes('链上金额与订单金额不一致')));
  assert.ok(document.body.find('p').some(node=>node.textContent?.includes('畅聊号：alice')),'operator sees the selected account before any confirmation');
  assert.ok(document.body.find('button').some(node=>node.textContent==='超时/无匹配订单：人工补录'));
  assert.equal(execute,0);
});

test('approved manual case keeps its case, amount, and creation rationale above the collapsed evidence',async()=>{
  install(); const saved=new Map(); const key=`chatflow.manual.deposit-case:owner:${item.txid}:3`;
  saved.set(key,JSON.stringify({case_id:'case-1'}));
  manualDepositCaseDialog({getManualDepositCase:async()=>({case_id:'case-1',status:'APPROVED',user_id:'user-1',username:'alice',nickname:'Alice',amount:'10.000000',asset:'USDT',reason_detail:'历史绑定与链上收据已核对'})},item,{actorId:'owner',storage:{getItem:k=>saved.get(k)??null,setItem(){},removeItem(){}}});
  await settle(); await settle();
  for(const text of ['畅聊号：alice','金额：10.000000 USDT','补录单：case-1','创建依据：历史绑定与链上收据已核对'])assert.ok(document.body.find('p').some(node=>node.textContent?.includes(text)));
  assert.equal(document.body.find('button').find(node=>node.textContent==='确认入账').disabled,true);
  assert.ok(document.body.find('details').length>0);
});

test('unknown deposit execution disables manual entry and only leaves the original operation query',async()=>{
  install(); let manualReads=0;
  walletRepairDialog({
    getDepositRepairCandidates:async()=>({receipt_id:'receipt-1',items:[{intent_id:'intent-1',username:'alice',user_id:'user-1',expected_amount:'10.000000',network:'TRON',intent_status:'EXPIRED'}]}),
    previewWalletRepair:async()=>({preview_id:'preview-1',digest:'digest',expected_version:1,expires_at:'2026-09-13T00:01:30Z',blockers:[],confirmation:{intent_id:'intent-1',username:'alice',user_id:'user-1',amount:'10.000000',asset:'USDT'}}),
    executeWalletRepair:async()=>{throw Error('network lost');},
    getManualDepositCaseContext:async()=>{manualReads++;return {};}
  },item,{actorId:'owner',storage});
  await settle(); await settle();
  document.body.find('button').find(node=>node.textContent==='选择').handlers.click();
  const form=document.body.find('form')[0];form.find('textarea')[0].value='已核对';form.handlers.submit({preventDefault(){}});
  await settle(); await settle();
  const check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;check.handlers.change();
  document.body.find('button').find(node=>node.textContent==='确认补入账').handlers.click();await settle();await settle();
  const manual=document.body.find('button').find(node=>node.textContent==='超时/无匹配订单：人工补录');
  assert.equal(manual.disabled,true);manual.handlers.click();await settle();
  assert.equal(manualReads,0);
  assert.ok(document.body.find('button').some(node=>node.textContent==='刷新当前操作状态'));
});
