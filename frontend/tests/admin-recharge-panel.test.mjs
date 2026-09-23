import test from 'node:test';
import assert from 'node:assert/strict';
import { rechargePanel as createRechargePanel } from '../src/admin-recharge-panel.js';
import { createAdminApi } from '../src/admin-api.js';

function rechargePanel(api,options={}){return createRechargePanel(api,{canManage:true,...options});}
class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';this.textContent='';this.disabled=false;this.checked=false;this.hidden=false;this.placeholder='';
    this.classList={add(){},toggle(){}};}
  append(...x){this.children.push(...x.filter(Boolean));}
  replaceChildren(...x){this.children=x;}
  setAttribute(name,value){this.attributes??={};this.attributes[name]=value;}
  getAttribute(name){return this.attributes?.[name];}
  addEventListener(n,h){this.handlers[n]=h;}
  find(tag){return [this,...this.children.flatMap(x=>x.find?.(tag)??[])].filter(x=>x.tag===tag);}
  createTHead(){const t=new Element('thead');this.children.push(t);return t;}
  createTBody(){const t=new Element('tbody');this.children.push(t);return t;}
  insertRow(){const r=new Element('tr');this.children.push(r);return r;}
}
const install=()=>{globalThis.document={createElement:t=>new Element(t)};};
const settle=()=>new Promise(r=>setImmediate(r));

const PENDING={items:[{id:'req-1',user_id:'alice',amount_usdt:'50.000000',fx_rate:'7.120000',
  fx_rate_stale:true,evidence_txid:'A'.repeat(64),status:'SUBMITTED'}]};
const DIRECTORY={items:[{cs_user_id:'agent-1',display_name:'官方客服小畅',payment_address:'T'.repeat(34),enabled:true,sort:1}]};
const FX={rate:'7.120000',fetched_at:'2026-09-21T12:00:00+00:00',stale:false,disclaimer:'参考估算，最终以客服结算为准'};
const VALUATION={caibi_face:'100.00',caibi_reference_usdt:'14.044944',usdt_obligation:'12.000000',
  valuation_rate:'7.120000',approved_unpaid_usdt:'0.000000'};

async function claimedPanel(api){
  const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();await settle();
  panel.find('button').find(b=>b.textContent==='处理请求')?.handlers.click();await settle();await settle();return panel;
}
function makeApi(calls){
  let pending=structuredClone(PENDING);pending.items[0].payment_verified=true;
  return {
    claimRecharge:async()=>{pending.items[0]={...pending.items[0],claimed_by:'staff',claim_expires_at:new Date(Date.now()+300000).toISOString()};return {...pending.items[0],claim_token:'lease'};},
    heartbeatRecharge:async()=>pending.items[0],
    settleRecharge:async(path,body,options)=>{calls.push(['bind',`/api/v1/recharge/admin/requests/${encodeURIComponent(path)}/settlement`,body,options]);return {state:'BOUND'};},
    getRechargePending:async()=>{calls.push(['pending']);return pending;},
    bindRechargeAdjustment:async(path,body,options)=>{calls.push(['bind',`/api/v1/recharge/admin/requests/${encodeURIComponent(path)}/bind`,body,options]);return {state:'BOUND'};},
    completeRechargeBinding:async(path,options)=>{calls.push(['complete',`/api/v1/recharge/admin/requests/${encodeURIComponent(path)}/complete-binding`,options]);return {status:'CREDITED',binding_state:'REGISTERED'};},
    rejectRecharge:async(path,body,options)=>{calls.push(['reject',`/api/v1/recharge/admin/requests/${encodeURIComponent(path)}/reject`,body,options]);return {status:'REJECTED'};},
    getRechargeDirectory:async()=>{calls.push(['directory']);return DIRECTORY;},
    upsertRechargeDirectory:async(body,options)=>{calls.push(['upsert',body,options]);return DIRECTORY.items[0];},
    getReserveValuation:async()=>{calls.push(['valuation']);return VALUATION;},
    getFxRate:async()=>{calls.push(['fx']);return FX;},
  };
}

test('directory writes use PUT and the ID path, never pass entry_id in body', async()=>{
  const calls=[];
  const api=createAdminApi({fetchImpl:async(url,options)=>{
    calls.push({url,options});
    return {ok:true,json:async()=>({id:'entry-1'})};
  }});
  await api.upsertRechargeDirectory({cs_user_id:'agent',display_name:'客服',payment_address:'TEST_ADDRESS'}, {idempotencyKey:'create'});
  await api.upsertRechargeDirectory({entry_id:'entry/1',cs_user_id:'agent',enabled:false}, {idempotencyKey:'disable'});
  assert.equal(calls[0].options.method,'PUT');
  assert.equal(calls[1].url,'/api/v1/recharge/admin/directory/entry%2F1');
  assert.equal(calls[1].options.method,'PUT');
  assert.equal('entry_id' in JSON.parse(calls[1].options.body),false);
});

test('case and directory reload buttons invoke the API again', async()=>{
  install();const calls=[];
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  panel.find('button').find(b=>b.title==='刷新充值请求').handlers.click();
  panel.find('button').find(b=>b.title==='刷新目录').handlers.click();
  await settle();await settle();
  assert.equal(calls.filter(([kind])=>kind==='pending').length,2);
  assert.equal(calls.filter(([kind])=>kind==='directory').length,2);
});

test('completion awaiting approval explicitly remains uncredited', async()=>{
  install();const calls=[];const api=makeApi(calls);
  api.completeRechargeBinding=async()=>({status:'PENDING_APPROVAL',binding_state:'BOUND'});
  const panel=await claimedPanel(api);
  panel.find('button').find(b=>b.textContent==='完成登记').handlers.click();
  await settle();await settle();
  assert.ok(panel.find('p').some(p=>p.textContent.includes('尚未执行')));
});

test('recharge panel renders pending cases with stale-marked reference rate and disclaimers', async()=>{
  install();const calls=[];
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  const texts = tag => panel.find(tag).map(x=>x.textContent).join('|');
  assert.ok(texts('td').includes('50.000000 USDT'));
  assert.ok(texts('td').includes('过期参考'));
  assert.ok(texts('p').includes('参考估算，最终以客服结算为准'));
  assert.ok(texts('span').includes('100.00'));          // 点钻账面
  assert.ok(texts('span').includes('14.044944'));       // 参考 USDT 估值
  assert.ok(texts('span').includes('12.000000'));       // 实际 USDT 义务
  assert.ok(calls.some(([k])=>k==='pending'));
});

test('bind submits adjustment id with idempotency key; empty id is rejected locally', async()=>{
  install();const calls=[];
  const panel=await claimedPanel(makeApi(calls));
  const inputs=panel.find('input');
  const adjInput=inputs.find(i=>i.placeholder==='财务调整 ID');
  const bindButton=panel.find('button').find(b=>b.textContent==='绑定调整');
  bindButton.handlers.click();await settle();
  const bindCalls=calls.filter(([k])=>k==='bind');
  assert.equal(bindCalls.length,0,'缺少调整 ID 时不得发出命令');
  adjInput.value='adj-1';
  inputs.find(i=>i.placeholder==='最终结算率（点钻/USDT）').value='7';
  bindButton.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='bind');
  assert.equal(sent.length,1);
  assert.equal(sent[0][1],'/api/v1/recharge/admin/requests/req-1/bind');
  assert.deepEqual(sent[0][2],{adjustment_id:'adj-1',final_rate:'7'});
  assert.equal(sent[0][3].idempotencyKey,'bind:req-1:adj-1:7');
});

test('complete registration surfaces authoritative reply instead of assuming success', async()=>{
  install();const calls=[];
  const panel=await claimedPanel(makeApi(calls));
  const complete=panel.find('button').find(b=>b.textContent==='完成登记');
  complete.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='complete');
  assert.equal(sent.length,1);
  assert.equal(sent[0][1],'/api/v1/recharge/admin/requests/req-1/complete-binding');
  assert.equal(sent[0][2].idempotencyKey,'register:req-1');
});

test('reject offers standard reasons and defaults to overdue payment with idempotency', async()=>{
  install();const calls=[];
  const panel=await claimedPanel(makeApi(calls));
  const rejectInput=panel.find('select').find(i=>i.getAttribute('aria-label')==='拒绝原因');
  const rejectButton=panel.find('button').find(b=>b.textContent==='拒绝');
  assert.equal(rejectInput.value,'用户未及时支付');
  assert.ok(rejectInput.children.some(option=>option.value==='用户主动取消'));
  rejectButton.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='reject');
  assert.equal(sent.length,1);
  assert.deepEqual(sent[0][2],{reason:'用户未及时支付'});
  assert.equal(sent[0][3].idempotencyKey,'reject:req-1');
});

test('directory upsert requires fields and supports update-by-id', async()=>{
  install();const calls=[];
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  const inputs=panel.find('input');
  const byPlaceholder=n=>inputs.find(i=>i.placeholder===n);
  const submit=panel.find('button').find(b=>b.textContent==='创建/修改目录条目');
  submit.handlers.click();await settle();
  assert.equal(calls.filter(([k])=>k==='upsert').length,0,'必填缺失不得提交');
  byPlaceholder('客服业务 user_id').value='agent-1';
  byPlaceholder('展示名').value='官方客服小畅';
  byPlaceholder('USDT (TRC20) 收款地址').value='T'.repeat(34);
  byPlaceholder('排序（数字）').value='2';
  byPlaceholder('按 ID 修改（留空＝创建）').value='entry-1';
  submit.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='upsert');
  assert.equal(sent.length,1);
  assert.equal(sent[0][1].entry_id,'entry-1');
  assert.equal(sent[0][1].sort,2);
  assert.equal(sent[0][2].idempotencyKey,'dir:entry-1:agent-1');
});

test('review queue shows occupied bindings; retry and evidence-gated release call review endpoint', async()=>{
  install();const calls=[];
  const api={
    ...makeApi(calls),
    getRechargeReviewQueue:async()=>({items:[{id:'binding-nr',request_id:'req-nr',request_status:'SUBMITTED',
      failure_reason:'RECHARGE_PROOF_INVALID',state:'NEEDS_REVIEW'}]}),
    reviewRecharge:async(requestId,body,options)=>{calls.push(['review',requestId,body,options]);
      return body.action==='retry'?{binding_state:'NEEDS_REVIEW',status:'SUBMITTED'}:{binding_state:'FAILED',status:'SUBMITTED'};},
  };
  const panel=rechargePanel(api);await settle();await settle();
  assert.ok(panel.find('td').some(td=>td.textContent==='RECHARGE_PROOF_INVALID'));
  const retry=panel.find('button').find(b=>b.textContent==='只读核实·重新登记');
  retry.handlers.click();await settle();
  const retrySent=calls.filter(([k])=>k==='review');
  assert.equal(retrySent.length,1);
  assert.equal(retrySent[0][1],'req-nr');
  assert.deepEqual(retrySent[0][2],{action:'retry',binding_id:'binding-nr'});
  assert.equal(retrySent[0][3].idempotencyKey,'review-retry:binding-nr');
  const releaseInput=panel.find('input').find(i=>i.placeholder?.includes('释放原因'));
  const release=panel.find('button').find(b=>b.textContent==='确证未执行·释放');
  release.handlers.click();await settle();
  assert.equal(calls.filter(([k])=>k==='review').length,1,'无原因不得释放');
  releaseInput.value='调整已确认被冲正';
  release.handlers.click();await settle();
  const releaseSent=calls.filter(([k])=>k==='review').at(-1);
  assert.deepEqual(releaseSent[2],{action:'release',reason:'调整已确认被冲正',binding_id:'binding-nr'});
  assert.equal(releaseSent[3].idempotencyKey,'review-release:binding-nr');
});

test('real admin API implements review queue, history, timeline and review commands', async()=>{
  const calls=[];
  const api=createAdminApi({fetchImpl:async(url,options)=>{
    calls.push({url,options});return {ok:true,json:async()=>({items:[]})};
  }});
  const cursor='2026-09-22T00:00:00+00:00|binding-id';
  await api.getRechargeReviewQueue({cursor,limit:20});
  await api.listRechargeRequests({status:'CREDITED',cursor,limit:20});
  await api.getRechargeTimeline('case/id');
  await api.reviewRecharge('case/id',{action:'release',binding_id:'b1',reason:'已核实拒绝'},
    {idempotencyKey:'release:b1'});
  assert.equal(new URL(calls[0].url,'https://test').pathname,'/api/v1/recharge/admin/review-queue');
  assert.equal(new URL(calls[0].url,'https://test').searchParams.get('cursor'),cursor);
  assert.equal(new URL(calls[1].url,'https://test').searchParams.get('status'),'CREDITED');
  assert.equal(calls[2].url,'/api/v1/recharge/admin/requests/case%2Fid/timeline');
  assert.equal(calls[3].options.method,'POST');
  assert.equal(calls[3].options.headers['Idempotency-Key'],'release:b1');
});

test('review queue network failures are not rendered as an empty queue', async()=>{
  install();const api={...makeApi([]),getRechargeReviewQueue:async()=>{throw new Error('offline');}};
  const panel=rechargePanel(api);await settle();
  const cells=panel.find('td').map(x=>x.textContent);
  assert.ok(cells.some(x=>x.includes('待核对队列加载失败')));
  assert.equal(cells.includes('无待核对绑定'),false);
});

test('late history response cannot replace a newer explicit refresh', async()=>{
  install();const pending=[];
  const api={...makeApi([]),listRechargeRequests:()=>new Promise(resolve=>pending.push(resolve))};
  const panel=rechargePanel(api);await settle();
  const more=panel.find('button').find(b=>b.textContent==='加载下一页');
  assert.equal(more.disabled,true,'分页请求完成前禁止下一页');
  panel.find('button').find(b=>b.title==='刷新订单查询').handlers.click();
  pending[1]({items:[{id:'new-data'}],next_cursor:null});await settle();
  pending[0]({items:[{id:'stale-data'}],next_cursor:'stale-cursor'});await settle();
  assert.ok(panel.find('td').some(x=>x.textContent==='new-data'));
  assert.equal(panel.find('td').some(x=>x.textContent==='stale-data'),false);
  assert.equal(more.disabled,true);
});

test('history section paginates with cursor and disables next page when exhausted', async()=>{
  install();const calls=[];
  const pages=[{items:[{id:'r1',user_id:'a',amount_usdt:'10.000000',status:'REJECTED',binding_state:'FAILED'}],
    next_cursor:'2026-09-21T00:00:00|c1'},
    {items:[{id:'r2',user_id:'a',amount_usdt:'20.000000',status:'CREDITED',binding_state:'REGISTERED',
      final_caibi_amount:'20.00'}],next_cursor:null}];
  const api={...makeApi(calls),listRechargeRequests:async filters=>{calls.push(['history',filters]);return pages.shift();}};
  const panel=rechargePanel(api);await settle();await settle();
  assert.ok(panel.find('td').some(td=>td.textContent==='r1'));
  const more=panel.find('button').find(b=>b.textContent==='加载下一页');
  assert.equal(more.disabled,false);
  more.handlers.click();await settle();
  assert.ok(panel.find('td').some(td=>td.textContent==='r2'));
  assert.equal(more.disabled,true,'无更多页时下一页按钮应禁用');
  const historyCalls=calls.filter(([k])=>k==='history');
  assert.deepEqual(historyCalls[0][1],{limit:20});
  assert.deepEqual(historyCalls[1][1],{cursor:'2026-09-21T00:00:00|c1',limit:20});
});


test('timeline retains only latest requested case and labels its identity', async()=>{
 install();const pending=[];const api={...makeApi([]),getRechargeTimeline:id=>new Promise(resolve=>pending.push({id,resolve}))};
 const panel=rechargePanel(api);await settle();const input=panel.find('input').find(x=>x.placeholder==='案件 ID');
 const button=panel.find('button').find(x=>x.textContent==='查看时间线');
 input.value='case-a';button.handlers.click();input.value='case-b';button.handlers.click();
 pending[1].resolve({request_id:'case-b',status:'CREDITED',items:[]});await settle();
 pending[0].resolve({request_id:'case-a',status:'SUBMITTED',items:[]});await settle();
 const text=panel.find('pre')[0].textContent;
 assert.ok(text.includes('case-b'));assert.equal(text.includes('SUBMITTED'),false);
});

test('late room result cannot append stale review buttons to current room',async()=>{
 install();const pending=[];const api={...makeApi([]),listTransferIntents:id=>new Promise(resolve=>pending.push({id,resolve}))};
 const panel=rechargePanel(api);await settle();const input=panel.find('input').find(x=>x.placeholder.startsWith('房间 ID'));
 input.value='!a:test';const a=panel.loadTransferIntents();input.value='!b:test';const b=panel.loadTransferIntents();
 pending[1].resolve({items:[{id:'intent-b',stage:'NEEDS_REVIEW'}]});await b;
 pending[0].resolve({items:[{id:'intent-a',stage:'NEEDS_REVIEW'}]});await a;
 assert.ok(panel.find('td').some(x=>x.textContent==='intent-b'));
 assert.equal(panel.find('td').some(x=>x.textContent==='intent-a'),false);
});

test('intent review has one in-flight command and displays server stage',async()=>{
 install();let resolveReview;let calls=0;
 const api={...makeApi([]),listTransferIntents:async()=>({items:[{id:'intent-1',stage:'NEEDS_REVIEW'}]}),reviewTransferIntent:()=>{calls++;return new Promise(r=>resolveReview=r);}};
 const panel=rechargePanel(api);await settle();panel.find('input').find(x=>x.placeholder.startsWith('房间 ID')).value='!a:test';await panel.loadTransferIntents();
 const confirm=panel.find('button').find(x=>x.textContent==='确认已应用');const fail=panel.find('button').find(x=>x.textContent==='确证未应用');
 confirm.handlers.click();fail.handlers.click();assert.equal(calls,1);assert.equal(confirm.disabled,true);assert.equal(fail.disabled,true);
 resolveReview({stage:'NEEDS_REVIEW',last_error_code:'MATRIX_STATE_DRIFT'});await settle();await settle();
 assert.ok(panel.find('p').some(x=>x.textContent.includes('NEEDS_REVIEW')));
 assert.equal(panel.find('button').find(x=>x.textContent==='确认已应用').disabled,false);
});

test('transfer AdminApi paths encode IDs and propagate rejected review',async()=>{
 const calls=[];const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:options.method!=='POST',status:503,json:async()=>({error:{code:'GROUP_TRANSFER_UNAVAILABLE',message:'协调关闭'}})};}});
 await api.listTransferIntents('!a/b:test');assert.ok(calls[0].url.includes('%2F'));
 await assert.rejects(api.reviewTransferIntent('id/one',{action:'confirm_applied'},{idempotencyKey:'review-1'}));
 assert.ok(calls[1].url.includes('id%2Fone'));assert.equal(calls[1].options.method,'POST');
});


test('empty lookup does not invalidate an existing valid in-flight lookup',async()=>{
 install();let timelineResolve,intentsResolve;
 const api={...makeApi([]),getRechargeTimeline:()=>new Promise(r=>timelineResolve=r),listTransferIntents:()=>new Promise(r=>intentsResolve=r)};
 const panel=rechargePanel(api);await settle();const input=panel.find('input').find(x=>x.placeholder==='案件 ID');const button=panel.find('button').find(x=>x.textContent==='查看时间线');
 input.value='valid-case';button.handlers.click();input.value='';await button.handlers.click();timelineResolve({request_id:'valid-case',status:'SUBMITTED',items:[]});await settle();assert.ok(panel.find('pre')[0].textContent.includes('valid-case'));
 const room=panel.find('input').find(x=>x.placeholder.startsWith('房间 ID'));room.value='!a:test';const lookup=panel.loadTransferIntents();room.value='';await panel.loadTransferIntents();intentsResolve({items:[{id:'valid-intent',stage:'COMPLETED'}]});await lookup;assert.ok(panel.find('td').some(x=>x.textContent==='valid-intent'));
});


test('other actor is read-only; unverified owned order cannot settle; forbidden heartbeat removes mutation',async()=>{
  install();let item={...PENDING.items[0],expires_at:new Date(Date.now()+7200000).toISOString(),claimed_by:'other',claim_expires_at:new Date(Date.now()+300000).toISOString()};
  const api={...makeApi([]),getRechargePending:async()=>({items:[item]}),claimRecharge:async()=>{item={...item,claimed_by:'staff'};return {...item,claim_token:'lease'};},heartbeatRecharge:async()=>{throw {status:403};}};
  const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();
  assert.equal(panel.find('button').some(b=>b.textContent==='接手处理'),false);
  assert.equal(panel.find('button').some(b=>b.textContent==='绑定调整'),false);
  item={...item,claimed_by:null};await panel.refreshOrders();
  panel.find('button').find(b=>b.textContent==='处理请求').handlers.click();await settle();await settle();
  assert.equal(panel.find('button').some(b=>b.textContent==='核验实际到账'),false);
  assert.equal(panel.find('button').some(b=>b.textContent==='绑定调整'),false);
  document.hidden=true;await panel.heartbeat();assert.equal(panel.find('button').some(b=>b.textContent==='核验实际到账'),false);
  document.hidden=false;await panel.heartbeat();assert.equal(panel.find('button').some(b=>b.textContent==='核验实际到账'),false);
  panel.dispose();
});

test('late pending response cannot restore another actor actions and disposed panel cannot claim',async()=>{
  install();const managedPending={items:[{...PENDING.items[0],expires_at:new Date(Date.now()+7200000).toISOString()}]};const pending=[];let claims=0;const api={...makeApi([]),getRechargePending:()=>new Promise(resolve=>pending.push(resolve)),claimRecharge:async()=>{claims++;return {};}};
  const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();
  const newer=panel.refreshOrders();pending[1]({items:[{...PENDING.items[0],claimed_by:'other',claim_expires_at:new Date(Date.now()+300000).toISOString()}]});await newer;
  pending[0](managedPending);await settle();assert.equal(panel.find('button').some(b=>b.textContent==='接手处理'),false);
  const latest=panel.refreshOrders();pending[2](managedPending);await latest;
  const claim=panel.find('button').find(b=>b.textContent==='处理请求');panel.dispose();claim.handlers.click();await settle();assert.equal(claims,0);
});

test('overdue managed order needs explicit finance review claim and reason',async()=>{
  install();let sent;
  const item={...PENDING.items[0],processing_stage:'NEEDS_REVIEW',expires_at:'2020-01-01T00:00:00Z'};
  const api={...makeApi([]),getRechargePending:async()=>({items:[item]}),claimRecharge:async(...args)=>{sent=args;return {};}};
  const normal=rechargePanel(api,{actor:{id:'staff'}});await settle();assert.equal(normal.find('button').some(b=>b.textContent.includes('认领')),false);normal.dispose();
  const panel=rechargePanel(api,{actor:{id:'staff'},canReview:true});await settle();
  const button=panel.find('button').find(b=>b.textContent==='处理待核对请求');button.handlers.click();await settle();assert.equal(sent,undefined);
  panel.find('input').find(i=>i.placeholder.includes('核对受理原因')).value='迟到账需核对';button.handlers.click();await settle();await settle();
  assert.deepEqual(sent[2],{review:true,reason:'迟到账需核对'});panel.dispose();
});

test('historical orders keep direct bind registration without unsupported claim',async()=>{
  install();const calls=[];const api=makeApi(calls);const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();
  assert.equal(panel.find('button').some(b=>b.textContent==='接手处理'),false);
  assert.ok(panel.find('button').some(b=>b.textContent==='绑定调整'));
  panel.find('input').find(i=>i.placeholder==='财务调整 ID').value='history-adj';
  panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）').value='7';
  panel.find('button').find(b=>b.textContent==='绑定调整').handlers.click();await settle();
  assert.equal(calls.find(([kind])=>kind==='bind')[1],'/api/v1/recharge/admin/requests/req-1/bind');panel.dispose();
});

test('independent administrator can approve a bound order without taking its claim',async()=>{
  install();let sent;
  const api={...makeApi([]),getRechargePending:async()=>({items:[{...PENDING.items[0],expires_at:new Date(Date.now()+7200000).toISOString(),claimed_by:'staff',claim_expires_at:new Date(Date.now()+300000).toISOString(),binding_adjustment_id:'approved-domain-adj',settlement_status:'SUBMITTED',settlement_submitted_by:'staff',binding_final_rate:'7',binding_final_caibi_amount:'350.00'}]}),adminReviewAdjustment:async(...args)=>{sent=args;return {status:'ADMIN_APPROVED'};}};
  const panel=rechargePanel(api,{actor:{id:'independent-admin'},canApprove:true});await settle();
  assert.equal(panel.find('button').some(b=>b.textContent==='接手处理'),false);
  panel.find('button').find(b=>b.textContent==='独立管理员批准结算').handlers.click();await settle();
  assert.equal(sent[0],'approved-domain-adj');assert.deepEqual(sent[1],{approve:true});panel.dispose();
  const own=rechargePanel(api,{actor:{id:'staff'},canApprove:true});await settle();
  assert.equal(own.find('button').some(b=>b.textContent==='独立管理员批准结算'),false);own.dispose();
});

test('public recharge queue pages by opaque server cursor',async()=>{
  install();const calls=[];
  const panel=rechargePanel({...makeApi([]),getRechargePending:async filters=>{calls.push(filters);return filters?.cursor?{items:[{id:'page-two',status:'SUBMITTED'}],next_cursor:null}:{items:[{id:'page-one',status:'SUBMITTED'}],next_cursor:'opaque-next'};}});await settle();
  const next=panel.find('button').find(button=>button.textContent==='下一页充值案件');assert.equal(next.disabled,false);
  next.handlers.click();await settle();assert.equal(calls.at(-1).cursor,'opaque-next');assert.equal(next.disabled,true);
  assert.ok(panel.find('td').some(node=>node.textContent==='page-two'));
  await panel.refreshOrders();assert.equal(calls.at(-1).cursor,'opaque-next');panel.dispose();
});

async function settlementPanel(overrides = {}, apiOverrides = {}) {
  install(); const calls=[];
  let item={...PENDING.items[0],amount_usdt:'10.000000',actual_received_usdt:'10.000000',fx_rate:'7.123456',fx_rate_stale:false,payment_verified:true,
    expires_at:new Date(Date.now()+7200000).toISOString(),...overrides};
  const api={...makeApi(calls),getFxRate:async()=>({rate:item.fx_rate,stale:item.fx_rate_stale,fetched_at:'2026-09-23T10:00:00Z'}),getRechargePending:async()=>({items:[item]}),claimRecharge:async()=>{item={...item,claimed_by:'staff',claim_expires_at:new Date(Date.now()+300000).toISOString()};return {...item,claim_token:'lease'};},
    prepareRechargeSettlement:async(...args)=>{calls.push(['prepare',...args]);return {status:'PENDING_APPROVAL',binding_adjustment_id:'prepared-1'};},
    executeRechargeSettlement:async(...args)=>{calls.push(['execute',...args]);return {status:'CREDITED',binding_state:'REGISTERED'};}};
  return {panel:await claimedPanel({...api,...apiOverrides}),calls};
}

test('saved settlement displays its frozen rate and continues the same execution',async()=>{
  const {panel,calls}=await settlementPanel({binding_adjustment_id:'saved-1',binding_final_rate:'6.000000',binding_final_caibi_amount:'60.00',settlement_approval_required:false});
  const rate=panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');
  assert.equal(rate.value,'6.000000');assert.equal(rate.disabled,true);
  assert.equal(panel.find('button').some(b=>b.textContent==='确认下发点钻'),false);
  panel.find('button').find(b=>b.textContent==='继续下发点钻').handlers.click();await settle();
  assert.equal(calls.some(c=>c[0]==='prepare'),false);assert.equal(calls.filter(c=>c[0]==='execute').length,1);panel.dispose();
});

test('failed settlement preparation never executes or reports points credited',async()=>{
  const {panel,calls}=await settlementPanel({}, {prepareRechargeSettlement:async()=>{throw Error('请求未确认');}});
  panel.find('button').find(b=>b.textContent==='确认下发点钻').handlers.click();await settle();
  assert.equal(calls.some(c=>c[0]==='execute'),false);
  assert.equal(panel.find('p').some(p=>p.textContent.includes('已入账并完成登记')),false);panel.dispose();
});
test('managed settlement defaults to fresh reference and fixed-base percentage shortcuts with decimal previews',async()=>{
  const {panel,calls}=await settlementPanel();
  const rate=panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');
  assert.equal(rate.value,'7.123456');
  for(const [label,value,amount] of [['-5%','6.767283','67.67'],['-1%','7.052221','70.52'],['基准','7.123456','71.23'],['+1%','7.194691','71.95'],['+5%','7.479629','74.80']]){
    const button=panel.find('button').find(b=>b.textContent===label);
    button.handlers.click();button.handlers.click();
    assert.equal(rate.value,value);assert.ok(panel.find('p').some(p=>p.textContent.includes(`最终点钻预览：${amount}`)));
  }
  rate.value='8.000001';rate.handlers.input();assert.ok(panel.find('p').some(p=>p.textContent.includes('最终点钻预览：80.00')));
  panel.find('button').find(b=>b.textContent==='确认下发点钻').handlers.click();await settle();
  assert.equal(calls.find(c=>c[0]==='prepare')[2].final_rate,'8.000001');
  assert.equal(calls.find(c=>c[0]==='execute')[2].claim_token,'lease');
  assert.deepEqual(calls.filter(c=>['prepare','execute'].includes(c[0])).map(c=>c[0]),['prepare','execute']);panel.dispose();
});
test('managed awaiting-payment orders show automatic detection and cannot submit settlement',async()=>{
  const {panel,calls}=await settlementPanel({payment_verified:false,actual_received_usdt:null});
  assert.ok(panel.find('p').some(p=>p.textContent.includes('等待系统确认到账')));
  assert.equal(panel.find('input').some(i=>i.placeholder==='到账交易哈希'),false);
  assert.equal(panel.find('button').some(b=>b.textContent==='确认下发点钻'),false);
  assert.equal(calls.some(c=>c[0]==='prepare'),false);panel.dispose();
});
for(const baseline of [{fx_rate:null},{fx_rate:'7.123456',fx_rate_stale:true}])test(`unusable baseline is never invented ${JSON.stringify(baseline)}`,async()=>{
  const {panel}=await settlementPanel(baseline);
  const rate=panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');assert.equal(rate.value,'');
  assert.equal(panel.find('button').find(b=>b.textContent==='+5%').disabled,true);
  assert.ok(panel.find('p').some(p=>p.textContent.includes('基准不可用')));panel.dispose();
});

test('decimal preview rounds half up without losing large integer precision',async()=>{
  for(const [amount,rate,expected] of [['0.005000','1.000000','0.01'],['9007199254740993.005000','1.000000','9007199254740993.01']]){
    const {panel}=await settlementPanel({actual_received_usdt:amount,fx_rate:rate});
    assert.ok(panel.find('p').some(p=>p.textContent.includes(`最终点钻预览：${expected}`)));panel.dispose();
  }
});
test('missing actual receipt and invalid final rates cannot prepare a settlement',async()=>{
  const {panel,calls}=await settlementPanel({actual_received_usdt:null});
  assert.equal(panel.find('button').find(b=>b.textContent==='确认下发点钻').disabled,true);panel.dispose();
  const good=await settlementPanel();const rate=good.panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');
  for(const value of ['0','1.0000001','-1','Infinity','1e5']){rate.value=value;good.panel.find('button').find(b=>b.textContent==='确认下发点钻').handlers.click();await settle();}
  assert.equal(good.calls.some(c=>c[0]==='prepare'),false);assert.equal(calls.some(c=>c[0]==='prepare'),false);good.panel.dispose();
});


test('settlement uses this load current FX snapshot, retaining historical order reference',async()=>{
  install();let fetches=0;
  let item={...PENDING.items[0],actual_received_usdt:'10.000000',payment_verified:true,
    fx_rate:'6.000000',fx_rate_stale:false,expires_at:new Date(Date.now()+7200000).toISOString()};
  const api={...makeApi([]),getFxRate:async()=>{fetches++;return {rate:'7.123456',stale:false,fetched_at:'2026-09-23T10:00:00Z'};},
    getRechargePending:async()=>({items:[item]}),claimRecharge:async()=>{item={...item,claimed_by:'staff',claim_expires_at:new Date(Date.now()+300000).toISOString()};return {...item,claim_token:'lease'};}};
  const panel=await claimedPanel(api);
  assert.equal(panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）').value,'7.123456');
  assert.ok(panel.find('td').some(td=>td.textContent.includes('6.000000')));
  assert.ok(panel.find('p').some(p=>p.textContent.includes('本次参考基准') && p.textContent.includes('7.123456')));
  assert.ok(panel.find('p').some(p=>p.textContent.includes('参考获取时间')));
  assert.equal(fetches,2,'initial shared load plus claim refresh each request FX once');
  api.getFxRate=async()=>{throw new Error('unavailable');};await panel.refreshOrders();
  assert.equal(panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）').value,'');
  assert.equal(panel.find('button').find(b=>b.textContent==='+5%').disabled,true);panel.dispose();
});

test('ordinary staff workbench separates admin tools and gives clear selected filters',async()=>{
 install();const calls=[];const panel=rechargePanel(makeApi(calls),{actor:{id:'staff'},canManage:false});await settle();await settle();
 assert.ok(!panel.find('h3').some(n=>/官方充值客服目录|群主转让意图|不确定登记/.test(n.textContent)));
 assert.equal(calls.filter(x=>x[0]==='directory').length,0);
 const tabs=panel.find('button');assert.ok(tabs.some(n=>n.textContent==='待处理请求'));assert.ok(tabs.some(n=>n.textContent==='我正在处理'));
 assert.ok(tabs.some(n=>n.title==='刷新充值请求' && n.textContent==='↻'));
 panel.dispose();
});
test('user cell uses display identity and prominent processing action',async()=>{
 install();const api=makeApi([]);api.getRechargePending=async()=>({items:[{id:'req',user_id:'private-id',user_display_name:'小林',user_chat_id:'lin2026',amount_usdt:'10.000000',expires_at:new Date(Date.now()+3600000).toISOString()}]});
 const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();await settle();
 assert.ok(panel.find('strong').some(n=>n.textContent==='小林'));
 assert.ok(panel.find('small').some(n=>n.textContent==='畅聊号：lin2026'));
 assert.ok(panel.find('button').some(n=>n.textContent==='处理请求' && n.className.includes('admin-primary')));panel.dispose();
});

test('order detail dialog is removed on disposal and ignores delayed response',async()=>{
 install();const mounted=[];
 document.body={append:node=>mounted.push(node)};
 const original=document.createElement;
 document.createElement=tag=>{const node=original(tag);node.focus=()=>{};
   node.showModal=()=>{node.open=true;};node.close=()=>{node.open=false;node.handlers.close?.();};
   node.remove=()=>{node.removed=true;};return node;};
 let resolve;const api={...makeApi([]),getRechargeTimeline:()=>new Promise(r=>{resolve=r;})};
 const panel=rechargePanel(api,{canManage:false});await settle();await settle();
 panel.find('button').find(b=>b.textContent==='查看记录').handlers.click();
 assert.equal(mounted.length,1);assert.equal(mounted[0].open,true);
 panel.dispose();assert.equal(mounted[0].removed,true);assert.equal(mounted[0].open,false);
 resolve({status:'CREDITED',items:[{action:'迟到响应'}]});await settle();
 assert.equal(mounted[0].find('strong').some(n=>n.textContent==='迟到响应'),false);
});

test('recharge settlement inputs live inside an operation dialog, not in the table row',async()=>{
 install();const panel=await claimedPanel(makeApi([]));
 const dialogs=panel.find('dialog').filter(d=>d.className.includes('admin-order-dialog'));
 assert.ok(dialogs.length>0);
 assert.ok(dialogs.some(d=>d.find('input').some(i=>i.placeholder==='最终结算率（点钻/USDT）')));
 assert.ok(panel.find('button').some(b=>b.textContent==='处理请求'));
 panel.dispose();
});


test('settlement shortcut and manual drafts survive a list refresh',async()=>{
 const {panel}=await settlementPanel();
 panel.find('button').find(b=>b.textContent==='+5%').handlers.click();
 await panel.refreshOrders();
 let rate=panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');
 assert.equal(rate.value,'7.479629');
 rate.value='8.120001';rate.handlers.input();await panel.refreshOrders();
 rate=panel.find('input').find(i=>i.placeholder==='最终结算率（点钻/USDT）');assert.equal(rate.value,'8.120001');panel.dispose();
});

test('late success of order A is never displayed inside order B operation dialog',async()=>{
 install();let complete;
 const api={...makeApi([]),getRechargePending:async()=>({items:[{...PENDING.items[0],id:'order-A'},{...PENDING.items[0],id:'order-B'}]}),completeRechargeBinding:()=>new Promise(r=>{complete=r;})};
 const panel=rechargePanel(api,{actor:{id:'staff'},canManage:false});await settle();await settle();
 panel.find('button').filter(b=>b.textContent==='处理请求')[0].handlers.click();
 panel.find('button').find(b=>b.textContent==='完成登记').handlers.click();await settle();
 panel.find('button').find(b=>b.textContent==='×').handlers.click();
 panel.find('button').filter(b=>b.textContent==='处理请求')[1].handlers.click();
 complete({status:'CREDITED',binding_state:'REGISTERED'});await settle();await settle();
 const orderB=panel.find('dialog').find(d=>d.find('p').some(p=>p.textContent.includes('订单 order-B')));
 assert.ok(orderB);assert.equal(orderB.find('p').some(p=>p.textContent.includes('已入账并完成登记')),false);
 assert.ok(panel.find('p').some(p=>p.textContent.includes('订单 order-A：已入账')));panel.dispose();
});

test('review dialog stays in review mode and keeps release draft after order refresh',async()=>{
 install();const create=document.createElement;
 document.createElement=tag=>{const node=create(tag);node.showModal=()=>{node.open=true;};node.close=()=>{node.open=false;node.handlers.close?.();};return node;};
 const api={...makeApi([]),getRechargeReviewQueue:async()=>({items:[{id:'binding',request_id:'req-1',request_status:'SUBMITTED'}]})};
 const panel=rechargePanel(api,{actor:{id:'staff'}});await settle();await settle();
 const table=panel.find('table').find(t=>t.className.includes('recharge-review'));
 table.find('button').find(b=>b.textContent==='处理请求').handlers.click();
 const input=panel.find('input').find(i=>i.placeholder==='释放原因（需确证未执行）');input.value='已核对调整拒绝';input.handlers.input();
 await panel.refreshOrders();
 const review=panel.find('dialog').find(d=>d.find('h2').some(h=>h.textContent==='处理待核对充值'));
 assert.equal(review.open,true);assert.equal(review.find('input')[0].value,'已核对调整拒绝');
 assert.equal(panel.find('dialog').some(d=>d.open&&d.find('h2').some(h=>h.textContent==='处理充值请求')),false);panel.dispose();
});
