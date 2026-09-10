import test from "node:test";
import assert from "node:assert/strict";
import { chainPanel } from "../src/admin-chain-panel.js";

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.handlers = {}; this.value = ""; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute() {}
  addEventListener(name, handler) { this.handlers[name] = handler; }
  find(tag) { return [this, ...this.children.flatMap(child => child.find(tag))].filter(item => item.tag === tag); }
}
const settle = () => new Promise(resolve => setImmediate(resolve));
const record = { txid: "b".repeat(64), log_index: 0, timestamp_ms: 1000, direction: "INFLOW", amount: "10.000001" };
const summary = { balance: "10.000001", last_success_ms: 1000, checkpoint_ms: 1000, coverage_start_ms: 0, observer_status: "OK", reconciliation: "SOURCE_MATCHED" };

test('chain absolute times and filter serialization use Beijing time in every browser timezone', async () => {
  const originalTimezone = process.env.TZ;
  try {
    for (const timezone of ['UTC', 'America/Los_Angeles']) {
      process.env.TZ = timezone;
      globalThis.document = { createElement: tag => new Element(tag) };
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
  globalThis.document = { createElement: tag => new Element(tag) };
  const calls = [];
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async filters => { calls.push(filters); return { items: [record], total: 30, snapshot: 44 }; },
    getChainTransaction: async () => ({ ...record, from_address: "source", to_address: "destination" }) });
  await settle();
  assert.ok(panel.find("td").some(item => item.textContent === "10.000001"));
  panel.find("button").find(item => item.textContent === "下一页").handlers.click();
  await settle();
  assert.equal(calls[1].snapshot, 44);
  assert.equal(calls[1].offset, 25);
  panel.find("button").find(item => item.textContent === "详情").handlers.click();
  await settle();
  assert.ok(panel.find("dd").some(item => item.textContent === "destination"));
});

test("chain panel exposes query outage and retry without fictitious empty records", async () => {
  globalThis.document = { createElement: tag => new Element(tag) };
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => { throw new Error("服务不可用"); } });
  await settle();
  assert.ok(panel.find("p").some(item => item.textContent?.includes("流水加载失败")));
  assert.equal(panel.find("td").length, 0);
  assert.equal(panel.find("button").find(item => item.type === "submit").disabled, false);
});

test("late detail response cannot overwrite a later selected transaction", async () => {
  globalThis.document = { createElement: tag => new Element(tag) };
  const pending = [];
  const panel = chainPanel({ getChainSummary: async () => summary,
    getChainTransactions: async () => ({ items: [record, { ...record, log_index: 1 }], total: 2, snapshot: 2 }),
    getChainTransaction: () => new Promise(resolve => pending.push(resolve)) });
  await settle();
  const actions = panel.find("button").filter(item => item.textContent === "详情");
  actions[0].handlers.click(); actions[1].handlers.click();
  pending[1]({ ...record, to_address: "second-selected" }); await settle();
  pending[0]({ ...record, to_address: "stale-first" }); await settle();
  assert.ok(panel.find("dd").some(item => item.textContent === "second-selected"));
  assert.ok(!panel.find("dd").some(item => item.textContent === "stale-first"));
});

test("ledger and conflicting evidence remain distinct in chain rows and detail", async () => {
  globalThis.document = { createElement: tag => new Element(tag) };
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
    assert.ok(panel.find("dd").some(item => item.textContent === value));
});

test("only allocated payout is displayed as settled; unknown linkage stays unverified", async () => {
  globalThis.document = { createElement: tag => new Element(tag) };
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
 globalThis.document={createElement:tag=>new Element(tag)};
 let fail=false,detailReads=0;const calls=[];
 const panel=chainPanel({getChainSummary:async()=>{if(fail)throw Error('offline');return summary;},getChainTransactions:async filters=>{calls.push(filters);if(fail)throw Error('offline');return {items:[record],total:60,snapshot:44};},getChainTransaction:async()=>({...record,to_address:`destination-${++detailReads}`})});await settle();
 panel.find('select')[0].value='INFLOW';panel.find('form')[0].handlers.submit({preventDefault(){}});await settle();
 panel.find('button').find(n=>n.textContent==='下一页').handlers.click();await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();
 fail=true;assert.equal(await panel.refresh(),false);
 assert.ok(panel.find('td').some(n=>n.textContent==='10.000001'));assert.ok(panel.find('dd').some(n=>n.textContent==='destination-1'));
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('过期')));assert.equal(calls.at(-1).offset,25);assert.equal(calls.at(-1).direction,'INFLOW');assert.equal(calls.at(-1).snapshot,undefined);
 fail=false;assert.equal(await panel.refresh(),true);assert.equal(detailReads,2);assert.ok(panel.find('dd').some(n=>n.textContent==='destination-2'));
});

test('chain detail refresh failure retains prior detail and reports false without discarding refreshed rows',async()=>{
 globalThis.document={createElement:tag=>new Element(tag)};let fail=false;
 const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:async()=>({items:[record],total:1,snapshot:44}),getChainTransaction:async()=>{if(fail)throw Error('detail offline');return {...record,to_address:'remembered'};}});await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();fail=true;
 assert.equal(await panel.refresh(),false);assert.ok(panel.find('dd').some(n=>n.textContent==='remembered'));assert.ok(panel.find('p').some(n=>n.textContent?.includes('详情')&&n.textContent?.includes('过期')));
});

test('late refreshed chain detail cannot replace a newer selection and duplicate refresh is blocked',async()=>{
 globalThis.document={createElement:tag=>new Element(tag)};let delay=false;const pending=[];
 const panel=chainPanel({getChainSummary:async()=>summary,getChainTransactions:async()=>({items:[record,{...record,log_index:1}],total:2,snapshot:44}),getChainTransaction:async(txid,index)=>{if(delay)return new Promise(resolve=>pending.push({index,resolve}));return {...record,to_address:'initial'};}});await settle();
 await panel.find('button').find(n=>n.textContent==='详情').handlers.click();delay=true;
 const refresh=panel.refresh();await settle();assert.equal(await panel.refresh(),false);
 const selection=panel.find('button').filter(n=>n.textContent==='详情')[1].handlers.click();
 pending[1].resolve({...record,to_address:'newer-selected'});await selection;
 pending[0].resolve({...record,to_address:'late-refresh'});assert.equal(await refresh,false);
 assert.ok(panel.find('dd').some(n=>n.textContent==='newer-selected'));assert.ok(!panel.find('dd').some(n=>n.textContent==='late-refresh'));
});
