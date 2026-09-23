import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';
import {supportPayoutPanel} from '../src/admin-support-payout-panel.js';

class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';this.textContent='';this.disabled=false;}
  append(...children){this.children.push(...children);}
  replaceChildren(...children){this.children=children;}
  addEventListener(name,fn){this.handlers[name]=fn;}
  setAttribute(){}
  find(tag){return [this,...this.children.flatMap(node=>node.find?.(tag)??[])].filter(node=>node.tag===tag);}
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
const button=(panel,text)=>panel.find('button').find(node=>node.textContent===text);

test('expired unstarted payout uses explicit review claim via scoped API',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const calls=[];
  const order={id:'expired',status:'REQUESTED',processing_stage:'NEEDS_REVIEW',amount:'10',expires_at:'2020-01-01T00:00:00Z'};
  const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>options.method==='POST'?{...order,processing_stage:'REVIEWING',claimed_by:'staff',claim_token:'review-lease',claim_expires_at:new Date(Date.now()+300000).toISOString()}:{items:[order]}};}});
  const panel=supportPayoutPanel(api,{actor:{id:'staff'}});await flush();
  assert.equal(button(panel,'接手处理'),undefined);
  button(panel,'复核认领过期提现').handlers.click();await flush();await flush();
  assert.equal(calls[1].url,'/api/v1/admin/support-orders/payouts/expired/review-claim');
  assert.deepEqual(JSON.parse(calls[1].options.body),{reason_code:'SUPPORT_PAYOUT_EXPIRED_REVIEW'});
  assert.ok(calls[1].options.headers['Idempotency-Key']);assert.ok(button(panel,'确认开始出款'));panel.dispose();
});

test('scoped payout API does not route through owner wallet commands',async()=>{
  const calls=[];const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>({})};}});
  await api.getSupportPayouts({limit:20});
  await api.supportPayoutCommand('order/1','begin-payment',{claim_token:'lease',expected_digest:'digest'},{idempotencyKey:'begin'});
  assert.equal(calls[0].url,'/api/v1/admin/support-orders/payouts?limit=20');
  assert.equal(calls[1].url,'/api/v1/admin/support-orders/payouts/order%2F1/begin-payment');
  assert.equal(calls[1].options.headers['Idempotency-Key'],'begin');
  await assert.rejects(api.supportPayoutCommand('id','bypass',{},{}),TypeError);
});

test('payout has no instructions before explicit begin and drops writes on lost heartbeat',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  let order={id:'payout-1',status:'REQUESTED',amount:'70.00',digest:'digest',final_receive:'10.000000'};
  const calls=[];
  const api={getSupportPayouts:async()=>({items:[order]}),supportPayoutCommand:async(id,action,body)=>{
    calls.push({id,action,body});
    if(action==='claim'){order={...order,status:'CLAIMED',claimed_by:'staff',claim_expires_at:new Date(Date.now()+300000).toISOString()};return {...order,claim_token:'lease'};}
    if(action==='begin-payment'){order={...order,execution_started_at:new Date().toISOString(),instructions:{target_address:'isolated-address',network:'TRON',amount:'10.000000'}};return order;}
    if(action==='heartbeat')throw {status:403};
    return order;
  }};
  const panel=supportPayoutPanel(api,{actor:{id:'staff'}});await flush();
  assert.equal(panel.find('p').some(node=>node.textContent.includes('isolated-address')),false);
  button(panel,'处理请求').handlers.click();await flush();await flush();
  assert.equal(button(panel,'确认开始出款')!==undefined,true);
  button(panel,'确认开始出款').handlers.click();await flush();await flush();
  assert.equal(calls.find(call=>call.action==='begin-payment').body.expected_digest,'digest');
  assert.equal(panel.find('p').some(node=>node.textContent.includes('isolated-address')),true);
  await panel.heartbeat();assert.equal(button(panel,'提交出款交易凭证'),undefined);panel.dispose();
});

test('expired started payout keeps evidence and reconciliation only, never a second payment',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const calls=[];const order={id:'late',status:'UNKNOWN',processing_stage:'NEEDS_REVIEW',claimed_by:'staff',claim_token:'lease',claim_expires_at:'2020-01-01T00:00:00Z',execution_started_at:'2019-12-31T23:59:00Z',amount:'10'};
  const panel=supportPayoutPanel({getSupportPayouts:async()=>({items:[order]}),supportPayoutCommand:async(id,action,body)=>{calls.push({action,body});return order;}},{actor:{id:'staff'}});await flush();
  assert.equal(button(panel,'接手处理'),undefined);assert.equal(button(panel,'确认开始出款'),undefined);
  assert.ok(button(panel,'提交出款交易凭证'));button(panel,'查询链上核验结果').handlers.click();await flush();
  assert.deepEqual(calls,[{action:'reconcile',body:{claim_token:'lease'}}]);await panel.heartbeat();assert.equal(calls.length,1);panel.dispose();
});

test('unknown payment permits audited candidate correction without starting another payment',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const calls=[];
  const order={id:'unknown',status:'UNKNOWN',claimed_by:'staff',claim_token:'lease',claim_expires_at:'2020-01-01T00:00:00Z',execution_started_at:'2019-12-31T23:59:00Z',candidate_txid:'old-proof',amount:'10'};
  const panel=supportPayoutPanel({getSupportPayouts:async()=>({items:[order]}),supportPayoutCommand:async(id,action,body)=>{calls.push({action,body});return order;}},{actor:{id:'staff'}});await flush();
  panel.find('input').find(input=>input.placeholder==='出款交易哈希').value='corrected-proof';button(panel,'更正出款交易凭证').handlers.click();await flush();
  assert.deepEqual(calls,[{action:'correct-candidate',body:{txid:'corrected-proof',reason_code:'PAYOUT_TXID_CORRECTION',claim_token:'lease'}}]);
  assert.equal(button(panel,'确认开始出款'),undefined);panel.dispose();
});

test('payout A late completion cannot appear as payout B success',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};let finishA;
 const orders=[{id:'A',status:'REQUESTED',amount:'10'},{id:'B',status:'REQUESTED',amount:'20'}];
 const api={getSupportPayouts:async()=>({items:orders}),supportPayoutCommand:async(id)=>{
   if(id==='A')return new Promise(resolve=>{finishA=resolve;});
   return {claimed_by:'staff',claim_token:'lease-B',claim_expires_at:new Date(Date.now()+300000).toISOString(),status:'CLAIMED'};
 }};
 const panel=supportPayoutPanel(api,{actor:{id:'staff'}});await flush();
 panel.find('button').filter(b=>b.textContent==='处理请求')[0].handlers.click();await flush();
 panel.find('button').find(b=>b.textContent==='×').handlers.click();
 panel.find('button').filter(b=>b.textContent==='处理请求')[1].handlers.click();await flush();
 finishA({status:'SETTLED'});await flush();await flush();
 const dialogB=panel.find('dialog').find(d=>d.find('p').some(p=>p.textContent==='订单 B'));
 assert.ok(dialogB);assert.equal(dialogB.find('p').some(p=>p.textContent.includes('已核验出款并完成结算')),false);panel.dispose();
});
