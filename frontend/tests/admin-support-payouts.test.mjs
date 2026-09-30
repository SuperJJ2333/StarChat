import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';
import {supportPayoutPanel} from '../src/admin-support-payout-panel.js';

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

test('expired unstarted payout uses explicit review claim via scoped API',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const calls=[];
  const order={id:'expired',status:'REQUESTED',processing_stage:'NEEDS_REVIEW',amount:'10',expires_at:'2020-01-01T00:00:00Z',...caps({can_claim:true})};
  const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>options.method==='POST'?{...order,processing_stage:'REVIEWING',claimed_by:'owner',claim_token:'review-lease',claim_expires_at:future,...caps({can_begin:true})}:{items:[order]}};}});
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();
  button(panel,'处理请求').handlers.click();await flush();await flush();
  const review=calls.find(c=>c.url.endsWith('/review-claim'));assert.equal(review.url,'/api/v1/admin/support-orders/payouts/expired/review-claim');
  assert.deepEqual(JSON.parse(review.options.body),{reason_code:'SUPPORT_PAYOUT_EXPIRED_REVIEW'});
  assert.ok(review.options.headers['Idempotency-Key']);assert.ok(button(panel,'拒绝提现'));panel.dispose();
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

test('payout has no full address before begin and drops writes on lost heartbeat',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'payout-1',status:'REQUESTED',amount:'70.00',digest:'a'.repeat(64),final_receive:'10.000000',claimed_by:'owner',claim_token:'lease',claim_expires_at:future,...caps({can_begin:true})};
  const calls=[];
  const api={getSupportPayouts:async()=>({items:[order]}),supportPayoutCommand:async(id,action,body)=>{
    calls.push({id,action,body});
    if(action==='heartbeat')throw {status:403};
    return order;
  }};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();
  button(panel,'处理请求').handlers.click();await flush();
  assert.doesNotMatch(visibleText(panel),/isolated-address/u);
  await panel.heartbeat();
  assert.equal(button(panel,'确认开始出款'),undefined);
  assert.equal(button(panel,'拒绝提现'),undefined);
  assert.deepEqual(calls.map(call=>call.action),['heartbeat']);panel.dispose();
});

test('expired started payout keeps evidence and reconciliation only, never a second payment',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const calls=[];const order={id:'late',status:'UNKNOWN',processing_stage:'NEEDS_REVIEW',claimed_by:'owner',claim_token:'lease',claim_expires_at:'2020-01-01T00:00:00Z',execution_started_at:'2019-12-31T23:59:00Z',amount:'10',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,readSupportPayoutAddress:async()=>({target_address:'Taddress',network:'TRON'}),discoverSupportPayout:async(id,token)=>{calls.push({id,token});return {status:'EMPTY',candidates:[]};}},{canOperate:true,actor:{id:'owner'}});await flush();
  assert.equal(button(panel,'接手处理'),undefined);assert.equal(button(panel,'确认开始出款'),undefined);
  button(panel,'处理请求').handlers.click();await flush();await flush();
  assert.ok(button(panel,'提交出款交易凭证'));button(panel,'查找链上出款').handlers.click();await flush();
  assert.deepEqual(calls,[{id:'late',token:'lease'}]);await panel.heartbeat();assert.equal(calls.length,1);panel.dispose();
});

test('unknown payment permits audited candidate correction without starting another payment',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const calls=[];
  const order={id:'unknown',status:'UNKNOWN',claimed_by:'owner',claim_token:'lease',claim_expires_at:'2020-01-01T00:00:00Z',execution_started_at:'2019-12-31T23:59:00Z',candidate_txid:'old-proof',amount:'10',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,readSupportPayoutAddress:async()=>({target_address:'Taddress',network:'TRON'}),supportPayoutCommand:async(id,action,body)=>{calls.push({action,body});return order;}},{canOperate:true,actor:{id:'owner'}});await flush();
  button(panel,'处理请求').handlers.click();await flush();await flush();
  panel.find('input').find(input=>input.placeholder==='出款交易哈希').value='corrected-proof';button(panel,'更正出款交易凭证').handlers.click();await flush();
  await approveFinancial(panel);
  assert.deepEqual(calls,[{action:'correct-candidate',body:{txid:'corrected-proof',reason_code:'PAYOUT_TXID_CORRECTION',claim_token:'lease',expected_version:1,expected_claim_version:1,proof:{operation_password:'isolated-test-operation-proof'}}}]);
  assert.equal(button(panel,'确认开始出款'),undefined);panel.dispose();
});

test('payout A late completion cannot appear as payout B success',async()=>{
 globalThis.document={createElement:tag=>new Element(tag),hidden:false};let finishA;
 const orders=[{id:'A',status:'REQUESTED',amount:'10',...caps({can_claim:true})},{id:'B',status:'REQUESTED',amount:'20',...caps({can_claim:true})}];
 const api={getSupportPayouts:async()=>({items:orders}),supportPayoutCommand:async(id)=>{
   if(id==='A')return new Promise(resolve=>{finishA=resolve;});
   return {claimed_by:'owner',claim_token:'lease-B',claim_expires_at:future,status:'REQUESTED',...caps({can_begin:true})};
 }};
 const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();
 panel.find('button').filter(b=>b.textContent==='处理请求')[0].handlers.click();await flush();
 panel.find('button').find(b=>b.textContent==='×').handlers.click();
 panel.find('button').filter(b=>b.textContent==='处理请求')[1].handlers.click();await flush();
 finishA({status:'SETTLED'});await flush();await flush();
 const dialogB=panel.find('dialog').find(d=>d.find('p').some(p=>p.textContent==='订单 B'));
 assert.ok(dialogB);assert.equal(dialogB.find('p').some(p=>p.textContent.includes('已核验出款并完成结算')),false);panel.dispose();
});

test('another staff lease is genuinely disabled by server capability and sends no write',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const calls=[];
  const order={id:'locked',status:'REQUESTED',claimed_by:'other',claim_expires_at:future,amount:'10.000000',...caps()};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),supportPayoutCommand:async(...args)=>{calls.push(args);}},{canOperate:true,actor:{id:'owner'}});
  await flush();
  const occupied=button(panel,'正被其他客服处理中');
  assert.ok(occupied);
  assert.equal(occupied.disabled,true);
  occupied.handlers.click?.();await flush();
  assert.deepEqual(calls,[]);
  panel.dispose();
});

test('owner opens read-only detail and uses separate confirmed takeover with fresh selected proof',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const calls=[];
  const order={id:'owned',status:'REQUESTED',claimed_by:'other',claim_expires_at:future,claim_version:4,amount:'10.000000',...caps({can_takeover:true})};
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    getWalletOperationSecurity:async()=>({auth_mode:'operation_password'}),
    takeoverSupportPayout:async(id,body,options)=>{calls.push({id,body,options});return {...order,claim_version:5,claimed_by:'owner',claim_token:'new-lease',...caps({can_begin:true})};}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();
  assert.equal(button(panel,'处理请求'),undefined);
  button(panel,'查看订单').handlers.click();await flush();
  assert.deepEqual(calls,[]);
  button(panel,'申请接管').handlers.click();await flush();
  assert.deepEqual(calls,[]);
  const proof=panel.find('input').find(input=>input.placeholder==='操作密码');
  assert.ok(proof);proof.value='synthetic-operation-password';
  button(panel,'确认接管').handlers.click();await flush();await flush();
  assert.equal(calls.length,1);
  assert.equal(calls[0].body.expected_claim_version,4);
  assert.equal(calls[0].body.proof.operation_password,'synthetic-operation-password');
  assert.ok(calls[0].body.reason_code);
  assert.ok(calls[0].options.idempotencyKey);
  assert.equal(proof.value,'');
  panel.dispose();
});

test('rate preparation stays cancellable, begin needs a second confirmation and latest terms',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  let order={id:'stage',status:'REQUESTED',funding_asset:'CAIBI',amount:'70.00',final_receive:'10.000000',digest:'a'.repeat(64),target_address_masked:'Txxx•••abc',claimed_by:'owner',claim_token:'lease',claim_expires_at:future,prepared_version:0,...caps({can_begin:true})};
  const calls=[];
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    supportPayoutCommand:async(id,action,body,options)=>{calls.push({action,body,options});
      if(action==='adjust-rate')order={...order,prepared_rate:body.new_rate,prepared_receive:'9.000000',prepared_version:order.prepared_version+1,prepared_digest:(order.prepared_version===0?'b':'c').repeat(64)};
      if(action==='begin-payment')order={...order,status:'CLAIMED',execution_started_at:new Date().toISOString(),...caps({can_evidence:true})};
      return order;},readSupportPayoutAddress:async()=>({target_address:'Tfull-private-address',network:'TRON'})};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();
  button(panel,'处理请求').handlers.click();await flush();
  assert.doesNotMatch(visibleText(panel),/Tfull-private-address/u);
  panel.find('input').find(input=>input.placeholder==='确认结算汇率（点钻/USDT）').value='7.500000';
  button(panel,'保存结算汇率').handlers.click();await flush();await flush();
  await approveFinancial(panel);
  assert.equal(calls.filter(call=>call.action==='begin-payment').length,0);
  assert.ok(button(panel,'拒绝提现'));
  assert.ok(button(panel,'保存结算汇率'));
  panel.find('input').find(input=>input.placeholder==='确认结算汇率（点钻/USDT）').value='7.600000';
  button(panel,'保存结算汇率').handlers.click();await flush();await flush();
  await approveFinancial(panel);
  assert.equal(calls.filter(call=>call.action==='adjust-rate').length,2);
  assert.equal(calls.filter(call=>call.action==='begin-payment').length,0);
  button(panel,'确认开始出款').handlers.click();await flush();
  assert.equal(calls.filter(call=>call.action==='begin-payment').length,0);
  assert.match(visibleText(panel),/Txxx•••abc/u);
  assert.doesNotMatch(visibleText(panel),/Tfull-private-address/u);
  button(panel,'确认且开始出款').handlers.click();await flush();await flush();
  await approveFinancial(panel);
  const begin=calls.find(call=>call.action==='begin-payment');
  assert.deepEqual({version:begin.body.expected_preparation_version,digest:begin.body.expected_digest},{version:2,digest:'c'.repeat(64)});
  assert.match(visibleText(panel),/Tfull-private-address/u);
  panel.dispose();
});

test('completed payment reveals full address for explicit copy and identity loss destroys access',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const oldNavigator=Object.getOwnPropertyDescriptor(globalThis,'navigator');
  const oldAdd=globalThis.addEventListener,oldRemove=globalThis.removeEventListener;
  const listeners=new Map(),copied=[],calls=[];let denyClipboard=false;
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{clipboard:{writeText:async value=>{if(denyClipboard)throw Error('denied');copied.push(value);}}}});
  globalThis.addEventListener=(name,fn)=>listeners.set(name,fn);
  globalThis.removeEventListener=name=>listeners.delete(name);
  const order={id:'paid',status:'UNKNOWN',amount:'10.00',execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    readSupportPayoutAddress:async()=>{calls.push('read');return {target_address:'Tfull-private-address',network:'TRON'};}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});
  try{
    await flush();button(panel,'处理请求').handlers.click();await flush();await flush();
    assert.match(visibleText(panel),/Tfull-private-address/u);
    button(panel,'复制收款地址').handlers.click();await flush();
    assert.deepEqual(copied,['Tfull-private-address']);
    assert.match(visibleText(panel),/完整收款地址已复制/u);
    denyClipboard=true;button(panel,'复制收款地址').handlers.click();await flush();
    assert.match(visibleText(panel),/复制失败/u);
    listeners.get('admin-session-expired')();await flush();
    assert.doesNotMatch(visibleText(panel),/Tfull-private-address/u);
    button(panel,'处理请求').handlers.click();await flush();await flush();
    assert.deepEqual(calls,['read']);
  }finally{
    panel.dispose();if(oldNavigator)Object.defineProperty(globalThis,'navigator',oldNavigator);else delete globalThis.navigator;
    globalThis.addEventListener=oldAdd;globalThis.removeEventListener=oldRemove;
  }
});

test('discovery distinguishes incomplete and conflict, and selection never automatically reconciles',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const calls=[];let discovery={status:'EMPTY',candidates:[]};
  const order={id:'discovery',claim_version:7,status:'UNKNOWN',execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    readSupportPayoutAddress:async()=>({target_address:'Tprivate-address',network:'TRON'}),
    discoverSupportPayout:async()=>discovery,
    selectSupportPayoutCandidate:async(id,body,options)=>{calls.push({id,body,options});return {...order,candidate_txid:body.txid};},
    supportPayoutCommand:async(id,action)=>{calls.push({id,action});return order;}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();await flush();
  button(panel,'查找链上出款').handlers.click();await flush();
  assert.match(visibleText(panel),/不代表未付款/u);
  discovery={status:'INCOMPLETE',candidates:[]};button(panel,'查找链上出款').handlers.click();await flush();
  assert.match(visibleText(panel),/不能排除已付款/u);
  discovery={status:'UNAVAILABLE',candidates:[]};button(panel,'查找链上出款').handlers.click();await flush();
  assert.match(visibleText(panel),/链上服务不可用/u);
  discovery={status:'COMPLETE',claim_version:7,evidence_version:0,candidates:[
    {txid:'conflicting-transaction-hash',log_index:0,amount:'10.000000',evidence_status:'CONFLICT',masked_target_address:'T••abc'},
    {txid:'verified-transaction-hash',log_index:2,amount:'10.000000',evidence_status:'VERIFIED',masked_target_address:'T••abc'}]};
  button(panel,'查找链上出款').handlers.click();await flush();
  assert.match(visibleText(panel),/发现 2 笔候选/u);
  assert.match(visibleText(panel),/须人工调查/u);
  assert.equal(panel.find('button').filter(node=>node.textContent==='选择此交易').length,1);
  assert.deepEqual(calls,[]);
  button(panel,'选择此交易').handlers.click();await flush();await flush();
  await approveFinancial(panel);
  assert.equal(calls.length,1);
  assert.deepEqual(calls[0].body,{claim_token:'lease',txid:'verified-transaction-hash',log_index:2,expected_claim_version:7,expected_version:1,proof:{operation_password:'isolated-test-operation-proof'}});
  assert.ok(calls[0].options.idempotencyKey);
  assert.ok(button(panel,'核验已选交易'));
  panel.dispose();
});

test('an unknown begin response refreshes authority without another payment command',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  let reads=0;const writes=[];
  const order={id:'uncertain',status:'REQUESTED',amount:'10.00',final_receive:'10.000000',digest:'a'.repeat(64),target_address_masked:'T••abc',claim_token:'lease',...caps({can_begin:true})};
  const api={getSupportPayouts:async()=>{reads++;return {items:[order]};},getSupportPayout:async()=>order,
    supportPayoutCommand:async(id,action,body,options)=>{writes.push({action,options});throw {code:'NETWORK_ERROR'};}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();
  button(panel,'确认开始出款').handlers.click();button(panel,'确认且开始出款').handlers.click();await flush();await flush();
  await approveFinancial(panel);
  assert.deepEqual(writes.map(entry=>entry.action),['begin-payment']);
  assert.equal(reads,2);
  assert.equal(button(panel,'确认且开始出款'),undefined);
  assert.match(visibleText(panel),/勿重复付款/u);
  panel.dispose();
});

test('forbidden payout command immediately removes stale preparation and evidence actions',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const writes=[];
  const order={id:'revoked',status:'REQUESTED',funding_asset:'CAIBI',prepared_version:0,claim_token:'lease',...caps({can_begin:true})};
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    supportPayoutCommand:async(id,action)=>{writes.push(action);throw {status:403};}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();
  panel.find('input').find(input=>input.placeholder==='确认结算汇率（点钻/USDT）').value='7.500000';
  button(panel,'保存结算汇率').handlers.click();await flush();
  await approveFinancial(panel);
  assert.equal(button(panel,'保存结算汇率'),undefined);
  assert.equal(button(panel,'确认开始出款'),undefined);
  assert.equal(button(panel,'拒绝提现'),undefined);
  assert.deepEqual(writes,['adjust-rate']);panel.dispose();
});

test('forbidden address read revokes the evidence UI without retaining its draft',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'read-revoked',status:'UNKNOWN',execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    readSupportPayoutAddress:async()=>{throw {status:403,message:'forbidden'};}},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();await flush();
  assert.equal(button(panel,'查找链上出款'),undefined);
  assert.equal(button(panel,'提交出款交易凭证'),undefined);
  assert.equal(panel.find('input').some(input=>input.placeholder==='出款交易哈希'),false);
  panel.dispose();
});

test('returning from a payout keeps the selected list filter and restores focus',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'mine',status:'REQUESTED',claimed_by:'owner',claim_token:'lease',...caps({can_begin:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'我正在处理').handlers.click();
  const opener=button(panel,'处理请求');opener.handlers.click();await flush();
  assert.ok(button(panel,'返回提现列表'));
  button(panel,'返回提现列表').handlers.click();
  assert.equal(button(panel,'我正在处理').getAttribute('aria-pressed'),'true');
  assert.notEqual(button(panel,'处理请求'),opener);
  assert.equal(globalThis.document.activeElement,button(panel,'处理请求'));
  assert.equal(panel.find('dialog')[0].hidden,true);
  assert.ok(panel.find('button').every(node=>node.type==='button'));
  panel.dispose();
});

test('forbidden list refresh removes a previously read full address and all old actions',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};let reads=0;
  const order={id:'private-refresh',status:'UNKNOWN',execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const api={getSupportPayouts:async()=>{if(++reads>1)throw {status:403,message:'forbidden'};return {items:[order]};},
    getSupportPayout:async()=>({...order,instructions:{target_address:'Tnested-private-address'}}),
    readSupportPayoutAddress:async()=>({target_address:'Tfull-private-address',network:'TRON'})};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();await flush();
  assert.match(visibleText(panel),/Tfull-private-address/u);
  await panel.refresh();
  assert.doesNotMatch(visibleText(panel),/Tfull-private-address|Tnested-private-address/u);
  assert.equal(button(panel,'查找链上出款'),undefined);
  assert.equal(button(panel,'处理请求'),undefined);
  panel.dispose();
});

test('forbidden detail read revokes previously projected evidence actions',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'private-detail',status:'UNKNOWN',execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),
    getSupportPayout:async()=>{throw {status:403,message:'forbidden'};}},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();
  assert.equal(button(panel,'查找链上出款'),undefined);
  assert.equal(button(panel,'提交出款交易凭证'),undefined);
  panel.dispose();
});

test('payment cannot begin until the server provides masked destination and payable amount',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'no-destination',status:'REQUESTED',amount:'10.00',digest:'a'.repeat(64),claim_token:'lease',...caps({can_begin:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();
  assert.equal(button(panel,'确认开始出款').disabled,true);
  assert.equal(button(panel,'确认且开始出款'),undefined);
  panel.dispose();
});

test('pre-payment writes stay disabled when capability is present but lease token is absent',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'missing-lease',status:'REQUESTED',funding_asset:'CAIBI',prepared_version:0,amount:'10.00',...caps({can_begin:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();
  assert.equal(button(panel,'保存结算汇率').disabled,true);
  assert.equal(button(panel,'拒绝提现').disabled,true);
  assert.equal(button(panel,'确认开始出款').disabled,true);
  panel.dispose();
});

test('rejected payout remains visible in history without a processing action',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'rejected',status:'REJECTED',amount:'10.00',...caps()};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]})},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'已完成与取消').handlers.click();
  assert.match(visibleText(panel),/提现单 rejected/u);
  assert.match(visibleText(panel),/已拒绝/u);
  assert.equal(button(panel,'处理请求'),undefined);
  panel.dispose();
});

test('staged receive and rejected projection reflect the server processing stage',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[
    {id:'staged',status:'REQUESTED',prepared_receive:'9.000000',final_receive:'10.000000',...caps()},
    {id:'rejected-stage',status:'CANCELLED',processing_stage:'REJECTED',...caps()}
  ]})},{canOperate:true,actor:{id:'owner'}});await flush();
  assert.match(visibleText(panel),/应付 9.000000 USDT/u);
  assert.doesNotMatch(visibleText(panel),/应付 10.000000 USDT|订单已取消/u);
  assert.match(visibleText(panel),/订单已拒绝/u);panel.dispose();
});

test('configured owner rejection collects a fresh selected proof rather than a cached grant',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const writes=[];
  const order={id:'owner-reject',status:'REQUESTED',owner_proof_required:true,claim_token:'lease',...caps({can_begin:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    getWalletOperationSecurity:async()=>({auth_mode:'totp'}),
    rejectSupportPayout:async(id,body)=>{writes.push(body);return {...order,status:'CANCELLED',processing_stage:'REJECTED',...caps()};}
  },{canOperate:true,actor:{id:'owner'}});await flush();button(panel,'处理请求').handlers.click();await flush();
  button(panel,'拒绝提现').handlers.click();await flush();
  assert.equal(writes.length,0);
  const proof=panel.find('input').find(node=>node.placeholder==='当前六位验证码');assert.ok(proof);
  assert.equal(button(panel,'确认拒绝提现').disabled,true);
  proof.value='123456';proof.handlers.input();button(panel,'确认拒绝提现').handlers.click();await flush();
  assert.deepEqual(writes,[{claim_token:'lease',reason_code:'PAYOUT_ADDRESS_INVALID',proof:{mfa_proof:'123456'}}]);
  assert.equal(proof.value,'');panel.dispose();
});

test('forbidden discovery immediately scrubs the full address and all evidence commands',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'discovery-revoked',status:'UNKNOWN',execution_started_at:'2020-01-01T00:00:00Z',claim_version:1,claim_token:'lease',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,
    readSupportPayoutAddress:async()=>({target_address:'Tprivate-revoked-address'}),discoverSupportPayout:async()=>{throw {status:403};}},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();await flush();assert.match(visibleText(panel),/Tprivate-revoked-address/u);
  button(panel,'查找链上出款').handlers.click();await flush();
  assert.doesNotMatch(visibleText(panel),/Tprivate-revoked-address/u);
  assert.equal(button(panel,'提交出款交易凭证'),undefined);assert.equal(button(panel,'查找链上出款'),undefined);panel.dispose();
});

test('unknown discovery evidence status is never selectable',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};
  const order={id:'unknown-candidate',status:'UNKNOWN',claim_version:3,execution_started_at:'2020-01-01T00:00:00Z',claim_token:'lease',...caps({can_evidence:true})};
  const panel=mountPayout({getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,readSupportPayoutAddress:async()=>({target_address:'Tsynthetic'}),
    discoverSupportPayout:async()=>({status:'COMPLETE',claim_version:3,evidence_version:0,candidates:[{txid:'unknown-status-transaction',log_index:0,evidence_status:'FUTURE_UNKNOWN'}]})},{canOperate:true,actor:{id:'owner'}});
  await flush();button(panel,'处理请求').handlers.click();await flush();button(panel,'查找链上出款').handlers.click();await flush();
  assert.equal(button(panel,'选择此交易'),undefined);panel.dispose();
});

test('started takeover uses evidence token and discovery versions for candidate selection',async()=>{
  globalThis.document={createElement:tag=>new Element(tag),hidden:false};const sent=[];
  const order={id:'evidence-takeover',status:'UNKNOWN',claim_version:4,evidence_version:0,claimed_by:'payer',execution_started_at:'2020-01-01T00:00:00Z',...caps({can_takeover:true})};
  const transferred={...order,claim_version:5,evidence_version:1,evidence_actor_id:'owner',evidence_token:'evidence-lease',...caps({can_evidence:true})};
  const api={getSupportPayouts:async()=>({items:[order]}),getSupportPayout:async()=>order,getWalletOperationSecurity:async()=>({auth_mode:'totp'}),
    takeoverSupportPayout:async(id,body)=>{sent.push(['takeover',body]);return transferred;},
    discoverSupportPayout:async(id,token)=>{sent.push(['discover',token]);return {status:'COMPLETE',claim_version:5,evidence_version:1,candidates:[{txid:'verified-evidence-transaction',log_index:6,evidence_status:'VERIFIED'}]};},
    selectSupportPayoutCandidate:async(id,body)=>{sent.push(['select',body]);return {...transferred,candidate_txid:body.txid};}};
  const panel=mountPayout(api,{canOperate:true,actor:{id:'owner'}});await flush();button(panel,'查看订单').handlers.click();await flush();button(panel,'申请接管').handlers.click();await flush();
  panel.find('input').find(node=>node.placeholder==='当前六位验证码').value='123456';button(panel,'确认接管').handlers.click();await flush();
  assert.equal(button(panel,'确认开始出款'),undefined);button(panel,'查找链上出款').handlers.click();await flush();button(panel,'选择此交易').handlers.click();await flush();
  await approveFinancial(panel);
  assert.deepEqual(sent[0],['takeover',{expected_claim_version:4,reason_code:'SUPPORT_PAYOUT_EVIDENCE_TAKEOVER',proof:{mfa_proof:'123456'}}]);
  assert.deepEqual(sent[1],['discover','evidence-lease']);assert.deepEqual(sent[2],['select',{claim_token:'evidence-lease',txid:'verified-evidence-transaction',log_index:6,expected_claim_version:5,expected_version:1,proof:{mfa_proof:'123456'}}]);panel.dispose();
});

function mountPayout(api,options){
 api.getWalletOperationSecurity??=async()=>({auth_mode:'operation_password'});
 const original=api.getSupportPayouts;api.getSupportPayouts=async(...args)=>{const page=await original(...args);return {...page,items:(page.items??[]).map(item=>({version:1,claim_version:1,...item}))};};
 return supportPayoutPanel(api,options);
}
async function approveFinancial(panel){
 await flush();await flush();
 const confirm=button(panel,'验证并确认本次操作');if(!confirm)return;
 const proof=panel.find('input').find(n=>n.type==='password');if(!proof)return;
 proof.value=proof.placeholder?.includes('六位')?'123456':'isolated-test-operation-proof';proof.handlers.input?.();confirm.handlers.click();await flush();await flush();
}
