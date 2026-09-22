import test from 'node:test';
import assert from 'node:assert/strict';
import { rechargePanel } from '../src/admin-recharge-panel.js';
import { createAdminApi } from '../src/admin-api.js';

class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';this.textContent='';this.disabled=false;this.checked=false;this.hidden=false;this.placeholder='';
    this.classList={add(){},toggle(){}};}
  append(...x){this.children.push(...x.filter(Boolean));}
  replaceChildren(...x){this.children=x;}
  setAttribute(){}
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

function makeApi(calls){
  return {
    getRechargePending:async()=>{calls.push(['pending']);return PENDING;},
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
  panel.find('button').find(b=>b.textContent==='刷新待处理案件').handlers.click();
  panel.find('button').find(b=>b.textContent==='刷新目录').handlers.click();
  await settle();await settle();
  assert.equal(calls.filter(([kind])=>kind==='pending').length,2);
  assert.equal(calls.filter(([kind])=>kind==='directory').length,2);
});

test('completion awaiting approval explicitly remains uncredited', async()=>{
  install();const calls=[];const api=makeApi(calls);
  api.completeRechargeBinding=async()=>({status:'PENDING_APPROVAL',binding_state:'BOUND'});
  const panel=rechargePanel(api);await settle();await settle();
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
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  const inputs=panel.find('input');
  const adjInput=inputs.find(i=>i.placeholder==='财务调整 ID');
  const bindButton=panel.find('button').find(b=>b.textContent==='绑定调整');
  bindButton.handlers.click();await settle();
  const bindCalls=calls.filter(([k])=>k==='bind');
  assert.equal(bindCalls.length,0,'缺少调整 ID 时不得发出命令');
  adjInput.value='adj-1';
  bindButton.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='bind');
  assert.equal(sent.length,1);
  assert.equal(sent[0][1],'/api/v1/recharge/admin/requests/req-1/bind');
  assert.deepEqual(sent[0][2],{adjustment_id:'adj-1'});
  assert.equal(sent[0][3].idempotencyKey,'bind:req-1:adj-1');
});

test('complete registration surfaces authoritative reply instead of assuming success', async()=>{
  install();const calls=[];
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  const complete=panel.find('button').find(b=>b.textContent==='完成登记');
  complete.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='complete');
  assert.equal(sent.length,1);
  assert.equal(sent[0][1],'/api/v1/recharge/admin/requests/req-1/complete-binding');
  assert.equal(sent[0][2].idempotencyKey,'register:req-1');
});

test('reject requires a reason and sends it with idempotency', async()=>{
  install();const calls=[];
  const panel=rechargePanel(makeApi(calls));await settle();await settle();
  const rejectInput=panel.find('input').find(i=>i.placeholder==='拒绝原因');
  const rejectButton=panel.find('button').find(b=>b.textContent==='拒绝');
  rejectButton.handlers.click();await settle();
  assert.equal(calls.filter(([k])=>k==='reject').length,0,'无原因不得拒绝');
  rejectInput.value='付款未到账';
  rejectButton.handlers.click();await settle();
  const sent=calls.filter(([k])=>k==='reject');
  assert.equal(sent.length,1);
  assert.deepEqual(sent[0][2],{reason:'付款未到账'});
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
  panel.find('button').find(b=>b.textContent==='刷新案件历史').handlers.click();
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
