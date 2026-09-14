import test from 'node:test';
import assert from 'node:assert/strict';
import {walletRepairDialog} from '../src/admin-wallet-repair-dialog.js';
import {manualDepositCaseDialog} from '../src/admin-manual-deposit-case.js';

class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.handlers={}; this.classList={add(){}}; this.style={}; this.value=''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  setAttribute() {}
  addEventListener(name,handler) { this.handlers[name]=handler; }
  remove() {}
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
