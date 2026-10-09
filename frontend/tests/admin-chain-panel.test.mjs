import test from "node:test";
import assert from "node:assert/strict";
import { chainPanel } from "../src/admin-chain-panel.js";

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.handlers = {}; this.value = ""; this.attributes = {}; this.classList = { add() {} }; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  remove() { this.removed = true; }
  focus() {}
  showModal() { this.open = true; }
  close() { this.open = false; this.handlers.close?.(); }
  getBoundingClientRect() { return { left: 0, right: 1, top: 0, bottom: 1 }; }
  find(tag) { return [this, ...this.children.flatMap(child => child.find(tag))].filter(item => item.tag === tag); }
}
const installDocument = () => globalThis.document = { body: new Element('body'), createElement: tag => new Element(tag) };
const settle = () => new Promise(resolve => setImmediate(resolve));
const record = { txid: "b".repeat(64), log_index: 0, timestamp_ms: 1000, direction: "INFLOW", amount: "10.000001" };
const summary = { balance: "10.000001", last_success_ms: 1000, checkpoint_ms: 1000, coverage_start_ms: 0, observer_status: "OK", reconciliation: "SOURCE_MATCHED" };
const distinctiveTxid = '0123456789abcdef'.repeat(4);
const withClipboard = async (writeText, run) => {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
  Object.defineProperty(globalThis, 'navigator', {configurable:true, value:{clipboard:{writeText}}});
  try { await run(); }
  finally { if(original)Object.defineProperty(globalThis,'navigator',original);else delete globalThis.navigator; }
};

test('chain list shortens a hash, keeps the log visible and copies the exact locator', async () => {
  await withClipboard(async value => { assert.equal(value, `${distinctiveTxid} / 7`); }, async () => {
    installDocument();
    const calls=[];
    const panel = chainPanel({getChainSummary:async()=>summary,
      getChainTransactions:async filters=>{calls.push(filters);return {items:[{...record,txid:distinctiveTxid,log_index:7}],total:1,snapshot:1};}});
    await settle();
    const cells=panel.find('td');
    assert.ok(cells.some(cell=>cell.textContent?.includes('01234567…abcdef')));
    assert.ok(cells.some(cell=>cell.textContent?.includes('#7')));
    assert.ok(!cells.some(cell=>cell.textContent?.includes(distinctiveTxid)));
    const copy=panel.find('button').find(button=>button.textContent==='复制完整哈希 / 日志');
    assert.equal(copy.type,'button');
    await copy.handlers.click();
    assert.ok(panel.find('p').some(item=>item.getAttribute('role')==='status'&&item.textContent?.includes('复制成功')));
    panel.find('input').find(item=>item.getAttribute('aria-label')==='完整交易哈希').value=distinctiveTxid;
    panel.find('form')[0].handlers.submit({preventDefault(){}});
    await settle();
    assert.equal(calls.at(-1).txid,distinctiveTxid);
  });
});

test('clipboard rejection gives a safe status and never claims a successful copy', async () => {
  await withClipboard(async()=>{throw Error(`clipboard denied ${distinctiveTxid}`);}, async()=>{
    installDocument();
    const panel=chainPanel({getChainSummary:async()=>summary,
      getChainTransactions:async()=>({items:[{...record,txid:distinctiveTxid,log_index:7}],total:1,snapshot:1})});
    await settle();
    const copy=panel.find('button').find(button=>button.textContent==='复制完整哈希 / 日志');
    assert.ok(copy);
    await copy.handlers.click();
    const feedback=panel.find('p').find(item=>item.getAttribute('role')==='status'&&item.textContent?.includes('复制失败'));
    assert.ok(feedback);
    assert.ok(!feedback.textContent.includes('复制成功'));
    assert.ok(!feedback.textContent.includes(distinctiveTxid));
    assert.ok(!feedback.textContent.includes('clipboard denied'));
  });
});

test('chain read errors do not echo a full searched transaction hash', async () => {
  installDocument();
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>{throw Error(`read failed ${distinctiveTxid}`);}});
  await settle();
  assert.ok(panel.find('p').some(item=>item.textContent?.includes('流水加载失败')));
  assert.ok(!panel.find('p').some(item=>item.textContent?.includes(distinctiveTxid)));
});

test('chain detail groups evidence, money path and platform association without exposing a full hash', async () => {
  const selected={...record,txid:distinctiveTxid,log_index:7,direction:'UNMATCHED_OUTFLOW',
    from_address:`T${'a'.repeat(33)}`,to_address:`T${'b'.repeat(33)}`};
  const copied=[];
  await withClipboard(async value=>{copied.push(value);},async()=>{
    installDocument();
    const panel=chainPanel({getChainSummary:async()=>summary,
      getChainTransactions:async()=>({items:[selected],total:1,snapshot:1}),
      getChainTransaction:async()=>selected});
    await settle();
    assert.ok(panel.find('td').some(item=>item.textContent==='未关联出款订单'));
    await panel.find('button').find(item=>item.textContent==='详情').handlers.click();
    const labels=document.body.find('section').map(item=>item.getAttribute('aria-label'));
    for(const label of ['链上证据','资金路径','平台关联'])assert.ok(labels.includes(label));
    assert.ok(document.body.find('p').some(item=>item.textContent?.includes('尚无可验证关联')));
    assert.ok(!document.body.find('p').some(item=>item.textContent?.includes('未申报')));
    assert.ok(!document.body.find('dd').some(item=>item.textContent?.includes(distinctiveTxid)));
    assert.ok(!document.body.find('dd').some(item=>item.textContent?.includes(selected.from_address)));
    assert.ok(!document.body.find('dd').some(item=>item.textContent?.includes(selected.to_address)));
    await document.body.find('button').find(item=>item.textContent==='复制完整交易哈希 / 日志').handlers.click();
    await document.body.find('button').find(item=>item.textContent==='复制完整转出地址').handlers.click();
    await document.body.find('button').find(item=>item.textContent==='复制完整转入地址').handlers.click();
    assert.deepEqual(copied,[`${distinctiveTxid} / 7`,selected.from_address,selected.to_address]);
    assert.ok(document.body.find('p').some(item=>item.getAttribute('role')==='status'&&item.textContent?.includes('复制成功')));
  });
});

test('chain detail keeps REVIEW and CONFLICT separate from settled payout', async () => {
  installDocument();
  const item={...record,direction:'UNMATCHED_OUTFLOW',platform_record:{kind:'PAYOUT',record_id:'order-1',
    ledger_status:'REVIEW',evidence_status:'CONFLICT',reason_code:'REVIEW_REQUIRED'}};
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>({items:[item],total:1,snapshot:1}),
    getChainTransaction:async()=>item});
  await settle();
  await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
  const visible=document.body.find('p').map(item=>item.textContent??'').join(' ');
  assert.ok(visible.includes('待处理'));
  assert.ok(visible.includes('证据冲突'));
  assert.ok(!visible.includes('提现已结算'));
});

test('access recheck closes detached detail and repair dialogs, then restores only an already read detail',async()=>{
  installDocument();let detailReads=0,listReads=0;
  const selected={...record,txid:distinctiveTxid,log_index:7,to_address:'destination'};
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>{listReads++;return {items:[selected],total:1,snapshot:1};},
    getChainTransaction:async()=>{detailReads++;return selected;},
    getDepositRepairCandidates:async()=>({receipt_id:'r',items:[]})},{actorId:'owner'});
  await settle();
  const activeDialogs=()=>document.body.find('dialog').filter(dialog=>dialog.open&&!dialog.removed);
  await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
  panel.find('select')[0].value='INFLOW';
  panel.find('button').find(button=>button.textContent==='充值补入账').handlers.click();await settle();
  assert.equal(activeDialogs().length,2);
  panel.suspendForAccessCheck();
  assert.equal(activeDialogs().length,0);
  assert.equal(panel.find('select')[0].value,'INFLOW');
  assert.equal(panel.find('td').length>0,true);
  panel.suspendForAccessCheck();
  panel.resumeReadDetail();
  assert.equal(activeDialogs().length,1);
  assert.ok(activeDialogs()[0].find('dd').some(item=>item.textContent==='destination'));
  assert.equal(detailReads,1,'restoring read detail cannot trigger another chain request');
  assert.equal(listReads,1,'access recheck cannot reload the list');
  panel.resumeReadDetail();assert.equal(activeDialogs().length,1);
});

test('pending detail cannot reopen or render from a late response during access recheck',async()=>{
  installDocument();let finishDetail;
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>({items:[record],total:1,snapshot:1}),
    getChainTransaction:()=>new Promise(resolve=>{finishDetail=resolve;})});
  await settle();
  const request=panel.find('button').find(button=>button.textContent==='详情').handlers.click();
  panel.suspendForAccessCheck();
  finishDetail({...record,to_address:'late-private-address'});await request;
  panel.resumeReadDetail();
  assert.equal(document.body.find('dialog').filter(dialog=>dialog.open&&!dialog.removed).length,0);
});

test('access recheck cancels an in-flight list read without leaving refresh controls locked',async()=>{
  installDocument();let release;let reads=0;
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>{reads++;return reads===2?new Promise(resolve=>{release=resolve;}):
      {items:[record],total:1,snapshot:1};}});
  await settle();const pending=panel.refresh();await settle();
  panel.suspendForAccessCheck();
  release({items:[{...record,amount:'999.000000'}],total:1,snapshot:2});
  assert.equal(await pending,false);
  panel.resumeReadDetail();
  assert.equal(panel.find('button').find(button=>button.textContent==='查询 / 刷新').disabled,false);
  assert.equal(await panel.refresh(),true);
  assert.equal(reads,3);
  assert.ok(panel.find('td').some(cell=>cell.textContent==='10.000001'));
  assert.ok(!panel.find('td').some(cell=>cell.textContent==='999.000000'));
});

test('owner transfer candidate requires complete distinct observed outflow details and preserves the current query',async()=>{
  installDocument();const selected={...record,txid:distinctiveTxid,log_index:7,direction:'UNMATCHED_OUTFLOW',
    asset:'USDT',network:'TRON',amount:'100000000000000001.000001',timestamp_ms:1780000000000,
    from_address:`T${'a'.repeat(33)}`,to_address:`T${'b'.repeat(33)}`};
  const other={...selected,log_index:8,amount:'2.000001',to_address:`T${'c'.repeat(33)}`};
  const calls=[],chosen=[];
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async filters=>{calls.push(filters);return filters.limit===100?
      {items:[selected,other],total:2,offset:0,snapshot:2}:{items:[selected],total:60,snapshot:1};},
    getChainTransaction:async(_txid,index)=>index===7?selected:other},
    {onSelectOwnerTransfer:value=>{chosen.push(value);return true;}});
  await settle();panel.find('select')[0].value='UNMATCHED_OUTFLOW';
  panel.find('form')[0].handlers.submit({preventDefault(){}});await settle();
  panel.find('button').find(button=>button.textContent==='下一页').handlers.click();await settle();
  await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
  const choose=document.body.find('button').find(button=>button.textContent==='用于所有者转出申报');
  assert.ok(choose);await choose.handlers.click();
  assert.deepEqual(calls.at(-1),{txid:distinctiveTxid,limit:100,offset:0});
  assert.deepEqual(chosen,[{txid:distinctiveTxid,log_index:7,amount:selected.amount,
    to_address:selected.to_address,timestamp_ms:selected.timestamp_ms}]);
  assert.equal(panel.find('select')[0].value,'UNMATCHED_OUTFLOW');
  await panel.refresh();assert.equal(calls.at(-1).offset,10);
  assert.equal(calls.at(-1).direction,'UNMATCHED_OUTFLOW');
});

test('ambiguous or incomplete owner transfer observations never reach the declaration callback',async()=>{
  const selected={...record,txid:distinctiveTxid,log_index:7,direction:'UNMATCHED_OUTFLOW',asset:'USDT',
    amount:'3.000001',timestamp_ms:1780000000000,to_address:`T${'b'.repeat(33)}`};
  const other={...selected,log_index:8};
  const cases=[
    ['too many',()=>({items:[selected],total:101,offset:0})],
    ['partial page',()=>({items:[selected],total:2,offset:0})],
    ['duplicate index',()=>({items:[selected,selected],total:2,offset:0})],
    ['same visible fields',()=>({items:[selected,other],total:2,offset:0})],
    ['selected missing',()=>({items:[other],total:1,offset:0})],
    ['incomplete detail',()=>({items:[selected],total:1,offset:0}),()=>({...selected,to_address:''})],
    ['evidence conflict',()=>({items:[selected],total:1,offset:0}),()=>({...selected,platform_record:{evidence_status:'CONFLICT'}})]
  ];
  for(const [label,page,selectedDetail] of cases){
    installDocument();let selectedCount=0;
    const panel=chainPanel({getChainSummary:async()=>summary,
      getChainTransactions:async filters=>filters.limit===100?page():{items:[selected],total:1,snapshot:1},
      getChainTransaction:async(_txid,index)=>index===7?(selectedDetail?.()??selected):other},
      {onSelectOwnerTransfer:()=>{selectedCount++;return true;}});
    await settle();await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
    const choose=document.body.find('button').find(button=>button.textContent==='用于所有者转出申报');
    assert.ok(choose,label);await choose.handlers.click();
    assert.equal(selectedCount,0,label);
    assert.ok(document.body.find('p').some(item=>item.getAttribute('role')==='status'&&item.textContent?.includes('人工核查')),label);
  }
});

test('suspending access during owner candidate lookup prevents a late callback',async()=>{
  installDocument();const selected={...record,txid:distinctiveTxid,log_index:7,direction:'UNMATCHED_OUTFLOW',
    asset:'USDT',to_address:`T${'b'.repeat(33)}`};
  let finishPage,chosen=0;
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async filters=>filters.limit===100?new Promise(resolve=>{finishPage=resolve;}):
      {items:[selected],total:1,snapshot:1},getChainTransaction:async()=>selected},
    {onSelectOwnerTransfer:()=>{chosen++;return true;}});
  await settle();await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
  const choose=document.body.find('button').find(button=>button.textContent==='用于所有者转出申报');
  const choosing=choose.handlers.click();panel.suspendForAccessCheck();
  finishPage({items:[selected],total:1,offset:0});await choosing;
  assert.equal(chosen,0);
});

test('menu snapshot keeps only one read page and restores draft, applied filters, scroll and open detail without chain GET',async()=>{
  installDocument();const originalWindow=globalThis.window;let pageScroll=312;
  globalThis.window={get scrollY(){return pageScroll;},scrollTo:(_x,y)=>{pageScroll=y;}};
  try {
    const pageItem={...record,txid:distinctiveTxid,asset:'USDT',network:'TRON',direction:'UNMATCHED_OUTFLOW',
      timestamp_ms:1780000000000,to_address:`T${'b'.repeat(33)}`};
    const calls={summary:0,list:[],detail:0};
    const api={getChainSummary:async()=>{calls.summary++;return summary;},
      getChainTransactions:async filters=>{calls.list.push(filters);return {items:[{...pageItem,log_index:filters.offset}],total:51,snapshot:44};},
      getChainTransaction:async(_txid,index)=>{calls.detail++;return {...pageItem,log_index:index,from_address:`T${'a'.repeat(33)}`};}};
    const panel=chainPanel(api);await settle();
    panel.find('select')[0].value='UNMATCHED_OUTFLOW';
    panel.find('form')[0].handlers.submit({preventDefault(){}});await settle();
    panel.find('button').find(button=>button.textContent==='下一页').handlers.click();await settle();
    panel.find('select')[0].value='INFLOW';
    panel.find('input').find(input=>input.getAttribute('aria-label')==='完整交易哈希').value=distinctiveTxid;
    panel.find('div').find(div=>div.className==='admin-table-scroll').scrollLeft=78;
    await panel.find('button').find(button=>button.textContent==='详情').handlers.click();
    const snapshot=panel.exportReadView();
    assert.ok(snapshot);assert.equal(snapshot.items.length,1);assert.equal(snapshot.offset,10);
    assert.equal(snapshot.activeFilters.direction,'UNMATCHED_OUTFLOW');
    assert.equal(snapshot.draftFilters.direction,'INFLOW');
    assert.equal(snapshot.pageScrollY,312);assert.equal(snapshot.scrollLeft,78);
    assert.equal(snapshot.detail.open,true);assert.equal(snapshot.detail.record.to_address,pageItem.to_address);
    const before={summary:calls.summary,list:calls.list.length,detail:calls.detail};
    panel.dispose();installDocument();pageScroll=0;
    const restored=chainPanel(api,{initialReadView:snapshot});await settle();
    assert.equal(calls.summary,before.summary);assert.equal(calls.list.length,before.list);
    assert.equal(calls.detail,before.detail);
    assert.equal(restored.find('select')[0].value,'INFLOW');
    assert.equal(restored.find('input').find(input=>input.getAttribute('aria-label')==='完整交易哈希').value,distinctiveTxid);
    assert.equal(restored.find('div').find(div=>div.className==='admin-table-scroll').scrollLeft,78);
    assert.equal(pageScroll,312);
    assert.ok(restored.find('p').some(item=>item.textContent?.includes('本页缓存于')));
    assert.ok(restored.find('p').some(item=>item.textContent?.includes('观察器最近成功扫描')));
    assert.ok(restored.find('p').some(item=>item.textContent?.includes('链上观察余额')&&item.textContent?.includes('不等于账本可用余额')));
    assert.equal(document.body.find('dialog').filter(dialog=>dialog.open&&!dialog.removed).length,1);
    assert.ok(document.body.find('dd').some(item=>item.textContent?.includes(pageItem.to_address.slice(0,8))));
    await restored.refresh();assert.equal(calls.summary,before.summary+1);assert.equal(calls.list.length,before.list+1);
  } finally {if(originalWindow===undefined)delete globalThis.window;else globalThis.window=originalWindow;}
});

test('invalid read view falls back to normal chain GET rather than displaying untrusted data',async()=>{
  installDocument();let reads=0;
  const panel=chainPanel({getChainSummary:async()=>summary,
    getChainTransactions:async()=>{reads++;return {items:[record],total:1,snapshot:1};}},
    {initialReadView:{items:Array.from({length:26},()=>record),total:26,offset:0}});
  await settle();assert.equal(reads,1);
  assert.ok(panel.find('td').some(item=>item.textContent==='10.000001'));
});

test('chain repair entry asks for grant and opens only after a second click',async()=>{
  installDocument();let granted=false,prompts=0,candidates=0;
  const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:async()=>({items:[record],total:1,snapshot:1}),
    getDepositRepairCandidates:async()=>{candidates++;return {receipt_id:'r',items:[]};}},
    {actorId:'owner',accessController:{canWrite:()=>granted,requestWriteGrant:async()=>{prompts++;return false;}}});
  await settle();const repair=panel.find('button').find(button=>button.textContent==='充值补入账');
  await repair.handlers.click();assert.equal(prompts,1);assert.equal(candidates,0);assert.equal(document.body.find('dialog').length,0);
  granted=true;await settle();assert.equal(candidates,0);
  await repair.handlers.click();await settle();assert.equal(candidates,1);assert.equal(document.body.find('dialog').length,1);
});

test('page size cannot skip records when changed during an initial request',async()=>{
  installDocument();const calls=[];let resolveFirst;
  const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:query=>{calls.push(query);return calls.length===1?new Promise(resolve=>resolveFirst=resolve):Promise.resolve({items:[record],total:100,snapshot:1});}});
  await settle();const size=panel.find('select').find(x=>x.className.includes('admin-page-size'));size.value='50';await size.handlers.change();
  resolveFirst({items:[record],total:100,snapshot:1});await settle();await panel.find('button').find(x=>x.textContent==='下一页').handlers.click();await settle();
  assert.equal(calls.at(-1).offset,10);assert.equal(calls.at(-1).limit,10);
});

test('read view validates page size 50 and its offset rather than a fixed 25',async()=>{
  const {validateChainReadView}=await import('../src/admin-chain-view-state.js');
  const view=validateChainReadView({pageSize:50,draftFilters:{},activeFilters:{},offset:50,snapshot:1,items:Array.from({length:50},(_,i)=>({...record,log_index:i,asset:'USDT'})),summary,total:100,pageScrollY:0,scrollLeft:0,cachedAt:1});
  assert.ok(view);assert.equal(view.pageSize,50);
});

test('chain absolute times and filter serialization use Beijing time in every browser timezone', async () => {
  const originalTimezone = process.env.TZ;
  try {
    for (const timezone of ['UTC', 'America/Los_Angeles']) {
      process.env.TZ = timezone;
      installDocument();
      const calls = [];
      const panel = chainPanel({getChainSummary: async () => summary,
        getChainTransactions: async filters => { calls.push(filters); return {items: [record], total: 1, snapshot: 1}; }});
      await settle();
      assert.ok(panel.find('td').some(item => item.textContent === '1970-01-01 08:00:01'));
      assert.ok(panel.find('p').some(item => item.textContent?.includes('覆盖起点：1970-01-01 08:00:00')));
      const dates = panel.find('input').filter(item => item.type === 'datetime-local');
      dates[0].value = '2026-09-10T08:00'; dates[1].value = '2026-09-10T09:00:30';
      panel.find('form')[0].handlers.submit({preventDefault(){}}); await settle();
      assert.equal(calls.at(-1).start_ms, Date.parse('2026-09-10T00:00:00Z'));
      assert.equal(calls.at(-1).end_ms, Date.parse('2026-09-10T01:00:30Z'));
      dates[0].value = 'invalid';
      const before = calls.length;
      panel.find('form')[0].handlers.submit({preventDefault(){}}); await settle();
      assert.equal(calls.length, before);
      assert.ok(panel.find('p').some(item => item.textContent?.includes('有效的北京时间')));
    }
  } finally { if (originalTimezone === undefined) delete process.env.TZ; else process.env.TZ = originalTimezone; }
});

test("chain panel uses stable pages, renders exact amount and fetches detail", async () => {
  installDocument();
  const calls = [];
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async filters => { calls.push(filters); return { items: [record], total: 30, snapshot: 44 }; },
    getChainTransaction: async () => ({ ...record, from_address: "source", to_address: "destination" }) });
  await settle();
  assert.ok(panel.find("td").some(item => item.textContent === "10.000001"));
  panel.find("button").find(item => item.textContent === "下一页").handlers.click();
  await settle();
  assert.equal(calls[1].snapshot, 44);
  assert.equal(calls[1].offset, 10);
  panel.find("button").find(item => item.textContent === "详情").handlers.click();
  await settle();
  assert.ok(document.body.find("dd").some(item => item.textContent === "destination"));
});

test("chain panel exposes query outage and retry without fictitious empty records", async () => {
  installDocument();
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => { throw new Error("服务不可用"); } });
  await settle();
  assert.ok(panel.find("p").some(item => item.textContent?.includes("流水加载失败")));
  assert.equal(panel.find("td").length, 0);
  assert.equal(panel.find("button").find(item => item.type === "submit").disabled, false);
});

test("late detail response cannot overwrite a later selected transaction", async () => {
  installDocument();
  const pending = [];
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => ({ items: [record, { ...record, log_index: 1 }], total: 2, snapshot: 2 }),
    getChainTransaction: () => new Promise(resolve => pending.push(resolve)) });
  await settle();
  const actions = panel.find("button").filter(item => item.textContent === "详情");
  actions[0].handlers.click(); actions[1].handlers.click();
  pending[1]({ ...record, to_address: "second-selected" }); await settle();
  pending[0]({ ...record, to_address: "stale-first" }); await settle();
  assert.ok(document.body.find("dd").some(item => item.textContent === "second-selected"));
  assert.ok(!document.body.find("dd").some(item => item.textContent === "stale-first"));
});

test("ledger and conflicting evidence remain distinct in chain rows and detail", async () => {
  installDocument();
  const linked = { ...record, platform_record: { kind: "DEPOSIT", record_id: "receipt-1",
    ledger_status: "CREDITED", user_id: "user-1", ledger_transaction_id: "ledger-1",
    intent_id: "intent-1", reason_code: "MATCHED", evidence_status: "CONFLICT" } };
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => ({ items: [linked], total: 1, snapshot: 1 }),
    getChainTransaction: async () => linked });
  await settle();
  assert.ok(panel.find("td").some(item => item.textContent?.includes("已入账")));
  assert.ok(panel.find("td").some(item => item.textContent?.includes("证据冲突")));
  panel.find("button").find(item => item.textContent === "详情").handlers.click();
  await settle();
  for (const value of ["user-1", "receipt-1", "ledger-1", "intent-1", "MATCHED"])
    assert.ok(document.body.find("dd").some(item => item.textContent === value));
});

test("only allocated payout is displayed as settled; unknown linkage stays unverified", async () => {
  installDocument();
  const linked = { ...record, direction: "UNMATCHED_OUTFLOW", platform_record: {
    kind: "PAYOUT", ledger_status: "SETTLED", evidence_status: "VERIFIED" } };
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => ({ items: [linked, record], total: 2, snapshot: 1 }) });
  await settle();
  assert.ok(panel.find("td").some(item => item.textContent === "提现转出"));
  assert.equal(panel.find("option").find(item => item.value === "UNMATCHED_OUTFLOW").textContent, "转出");
  assert.ok(panel.find("td").some(item => item.textContent?.includes("提现已结算")));
  assert.ok(panel.find("td").some(item => item.textContent === "尚未核定"));
});

test('global chain refresh preserves filters page rows and selected detail on failure and refetches on recovery',async()=>{
 installDocument();
 let fail=false,detailReads=0;const calls=[];
 const panel=chainPanel({getChainSummary:async()=>{if(fail)throw Error('offline');return summary;},getChainTransactions:async filters=>{calls.push(filters);if(fail)throw Error('offline');return {items:[record],total:60,snapshot:44};},getChainTransaction:async()=>({...record,to_address:`destination-${++detailReads}`})});await settle();
 panel.find('select')[0].value='INFLOW';panel.find('form')[0].handlers.submit({preventDefault(){}});await settle();
 panel.find('button').find(n=>n.textContent==='下一页').handlers.click();await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();
 fail=true;assert.equal(await panel.refresh(),false);
 assert.ok(panel.find('td').some(n=>n.textContent==='10.000001'));assert.ok(document.body.find('dd').some(n=>n.textContent==='destination-1'));
 assert.ok(document.body.find('p').some(n=>n.textContent?.includes('过期')));assert.equal(calls.at(-1).offset,10);assert.equal(calls.at(-1).direction,'INFLOW');assert.equal(calls.at(-1).snapshot,undefined);
 fail=false;assert.equal(await panel.refresh(),true);assert.equal(detailReads,2);assert.ok(document.body.find('dd').some(n=>n.textContent==='destination-2'));
});

test('chain detail refresh failure retains prior detail and reports false without discarding refreshed rows',async()=>{
 installDocument();let fail=false;
 const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:async()=>({items:[record],total:1,snapshot:44}),getChainTransaction:async()=>{if(fail)throw Error('detail offline');return {...record,to_address:'remembered'};}});await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();fail=true;
 assert.equal(await panel.refresh(),false);assert.ok(document.body.find('dd').some(n=>n.textContent==='remembered'));assert.ok(document.body.find('p').some(n=>n.textContent?.includes('详情')&&n.textContent?.includes('过期')));
});

test('late refreshed chain detail cannot replace a newer selection and duplicate refresh is blocked',async()=>{
 installDocument();let delay=false;const pending=[];
 const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:async()=>({items:[record,{...record,log_index:1}],total:2,snapshot:44}),getChainTransaction:async(txid,index)=>{if(delay)return new Promise(resolve=>pending.push({index,resolve}));return {...record,to_address:'initial'};}});await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();delay=true;
 const refresh=panel.refresh();await settle();assert.equal(await panel.refresh(),false);
 const selection=panel.find('button').filter(n=>n.textContent==='详情')[1].handlers.click();
 pending[1].resolve({...record,to_address:'newer-selected'});await selection;
 pending[0].resolve({...record,to_address:'late-refresh'});assert.equal(await refresh,false);
 assert.ok(document.body.find('dd').some(n=>n.textContent==='newer-selected'));assert.ok(!document.body.find('dd').some(n=>n.textContent==='late-refresh'));
});

test('validated deposit needs explicit submission and refreshes the current chain page after execution', async () => {
  installDocument();
  const pageCalls = [];
  const executes = [];
  const storage = new Map();
  const api = {
    getChainSummary: async () => summary,
    getChainTransactions: async filters => { pageCalls.push(filters); return {items:[pageCalls.length===4?{...record,platform_record:{kind:'DEPOSIT',ledger_status:'CREDITED',evidence_status:'VERIFIED'}}:record],total:50,snapshot:17}; },
    getDepositRepairCandidates: async () => ({receipt_id:'receipt-1',items:[{intent_id:'intent-1',username:'u',nickname:'n',expected_amount:'10.000000',network:'tron-mainnet',intent_status:'EXPIRED'}]}),
    previewWalletRepair: async () => ({preview_id:'preview-1',digest:'a'.repeat(64),expected_version:1,expires_at:'2026-09-13T00:01:30Z',blockers:[],confirmation:{intent_id:'intent-1',amount:'10.000000'}}),
    executeWalletRepair: async (...args) => { executes.push(args); return {status:'EXECUTED',operation_id:'operation-1'}; }
  };
  const originalStorage = globalThis.localStorage;
  globalThis.localStorage = {getItem:key=>storage.get(key) ?? null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)};
  try {
    const panel = chainPanel(api,{actorId:'owner-1'});
    await settle();
    panel.find('select')[0].value='INFLOW';
    panel.find('form')[0].handlers.submit({preventDefault(){}}); await settle();
    panel.find('button').find(item=>item.textContent==='下一页').handlers.click(); await settle();
    panel.find('button').find(item=>item.textContent==='充值补入账').handlers.click();
    await settle();
    document.body.find('button').find(item=>item.textContent==='选择').handlers.click();
    const command = document.body.find('form')[0];
    command.find('textarea')[0].value = '已核对付款归属与订单';
    command.handlers.submit({preventDefault(){}});
    await settle(); await settle();
    assert.equal(executes.length,0,'preflight must not write a financial command');
    assert.ok(document.body.find('p').some(item=>item.textContent?.includes('预检通过后请勾选确认')));
    const check = document.body.find('input').find(item=>item.type==='checkbox');
    check.checked = true; check.handlers.change();
    document.body.find('button').find(item=>item.textContent==='确认补入账').handlers.click();
    await settle(); await settle();
    assert.equal(executes.length,1);
    assert.equal(executes[0][0],'deposit-repairs');
    assert.deepEqual(executes[0][1],{preview_id:'preview-1',digest:'a'.repeat(64),expected_version:1,operation_id:executes[0][1].operation_id,confirmed:true});
    assert.equal(executes[0][2].idempotencyKey,executes[0][1].operation_id);
    assert.equal(pageCalls.length,4,'execution refreshes the visible chain page');
    assert.equal(pageCalls[3].offset,10);
    assert.equal(pageCalls[3].direction,'INFLOW');
    assert.ok(panel.find('td').some(item=>item.textContent?.includes('已入账')));
  } finally { globalThis.localStorage = originalStorage; }
});

test('blocked preview explains the blocker and cannot submit a deposit command', async () => {
  installDocument();
  const calls = [];
  const panel = chainPanel({
    getChainSummary: async () => summary,
    getChainTransactions: async () => ({items:[record],total:1,snapshot:17}),
    getDepositRepairCandidates: async () => ({receipt_id:'receipt-1',items:[{intent_id:'intent-1',expected_amount:'10.000000',network:'tron-mainnet',intent_status:'EXPIRED'}]}),
    previewWalletRepair: async () => ({blockers:['AMOUNT_MISMATCH'],confirmation:{intent_id:'intent-1'}}),
    executeWalletRepair: async (...args) => calls.push(args)
  },{actorId:'owner-1'});
  await settle();
  panel.find('button').find(item=>item.textContent==='充值补入账').handlers.click(); await settle();
  document.body.find('button').find(item=>item.textContent==='选择').handlers.click();
  const command = document.body.find('form')[0]; command.find('textarea')[0].value='金额复核';
  command.handlers.submit({preventDefault(){}}); await settle(); await settle();
  assert.ok(document.body.find('p').some(item=>item.textContent?.includes('链上金额与订单金额不一致')));
  const blockedConfirm=document.body.find('button').find(item=>item.textContent==='确认补入账');
  assert.equal(blockedConfirm.disabled,true);
  assert.equal(calls.length,0);
});

test('recovered executed operation refreshes the chain page without replaying it', async () => {
  installDocument();
  const pages = [], reads = [];
  const storage = new Map();
  const key = `chatflow.manual.repair:owner-1:deposit-repairs:${record.txid}:0`;
  storage.set(key,JSON.stringify({operation_id:'operation-1'}));
  const originalStorage = globalThis.localStorage;
  globalThis.localStorage = {getItem:key=>storage.get(key) ?? null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)};
  try {
    const panel = chainPanel({
      getChainSummary: async () => summary,
      getChainTransactions: async filters => { pages.push(filters); return {items:[record],total:1,snapshot:17}; },
      getWalletRepair: async (kind,id) => { reads.push([kind,id]); return {status:'EXECUTED',operation_id:id}; },
      executeWalletRepair: async () => { throw Error('must not replay'); }
    },{actorId:'owner-1'});
    await settle();
    panel.find('button').find(item=>item.textContent==='充值补入账').handlers.click(); await settle();
    document.body.find('button').find(item=>item.textContent==='刷新当前操作状态').handlers.click();
    await settle(); await settle();
    assert.deepEqual(reads,[['deposit-repairs','operation-1']]);
    assert.equal(pages.length,2);
    assert.equal(storage.has(key),false);
  } finally { globalThis.localStorage = originalStorage; }
});

test('executed deposit survives local journal cleanup and reports a failed list refresh separately', async () => {
  installDocument();
  let refresh = false;
  const storage = new Map();
  const originalStorage = globalThis.localStorage;
  globalThis.localStorage = {getItem:key=>storage.get(key) ?? null,setItem:(key,value)=>storage.set(key,value),removeItem:()=>{throw Error('storage offline');}};
  try {
    const panel = chainPanel({
      getChainSummary: async () => summary,
      getChainTransactions: async () => { if(refresh) throw Error('chain offline'); return {items:[record],total:1,snapshot:17}; },
      getDepositRepairCandidates: async () => ({receipt_id:'receipt-1',items:[{intent_id:'intent-1',expected_amount:'10.000000',network:'tron-mainnet',intent_status:'EXPIRED'}]}),
      previewWalletRepair: async () => ({preview_id:'preview-1',digest:'a'.repeat(64),expected_version:1,expires_at:'2026-09-13T00:01:30Z',blockers:[],confirmation:{intent_id:'intent-1'}}),
      executeWalletRepair: async () => { refresh = true; return {status:'EXECUTED',operation_id:'operation-1'}; }
    },{actorId:'owner-1'});
    await settle();
    panel.find('button').find(item=>item.textContent==='充值补入账').handlers.click(); await settle();
    document.body.find('button').find(item=>item.textContent==='选择').handlers.click();
    const command = document.body.find('form')[0]; command.find('textarea')[0].value='已核对'; command.handlers.submit({preventDefault(){}});
    await settle(); await settle();
    const check = document.body.find('input').find(item=>item.type==='checkbox'); check.checked=true; check.handlers.change();
    document.body.find('button').find(item=>item.textContent==='确认补入账').handlers.click(); await settle(); await settle();
    assert.ok(document.body.find('p').some(item=>item.textContent?.includes('已入账')&&item.textContent?.includes('列表刷新失败')));
    assert.ok(!document.body.find('p').some(item=>item.textContent?.includes('结果未确认')));
  } finally { globalThis.localStorage = originalStorage; }
});
