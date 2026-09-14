import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';
import * as repairDialog from '../src/admin-wallet-repair-dialog.js';
import {manualDepositCaseDialog} from '../src/admin-manual-deposit-case.js';

test('manual deposit case API uses the frozen case endpoints and idempotency keys', async () => {
  const calls = [];
  const api = createAdminApi({fetchImpl: async (url, options = {}) => {
    calls.push({url, options});
    return {ok: true, headers: {get: () => 'application/json'}, json: async () => ({case_id: 'case-1', status: 'PENDING_DECISION'})};
  }});

  await api.getManualDepositCaseContext({txid: 'a'.repeat(64), log_index: 7});
  await api.createManualDepositCase({receipt_id: 'receipt-1', user_id: 'user-1', reason_detail: '链上收据与历史绑定已核对', ownership_attestation: true}, {idempotencyKey: 'create-key'});
  await api.decideManualDepositCase('case-1', {decision: 'APPROVED', reason_detail: '批准依据已复核', confirmed: true}, {idempotencyKey: 'decision-key'});
  await api.previewManualDepositCase('case-1');
  await api.executeManualDepositCase('case-1', {preview_id: 'preview-1', digest: 'digest', expected_version: 1, operation_id: 'operation-1', confirmed: true}, {idempotencyKey: 'operation-1'});
  await api.getManualDepositCaseOperation('operation-1');

  assert.deepEqual(calls.map(({url, options}) => [url, options.method ?? 'GET', options.headers?.['Idempotency-Key']]), [
    ['/api/v1/admin/wallet/manual/manual-deposit-cases/context?txid=' + 'a'.repeat(64) + '&log_index=7', 'GET', undefined],
    ['/api/v1/admin/wallet/manual/manual-deposit-cases', 'POST', 'create-key'],
    ['/api/v1/admin/wallet/manual/manual-deposit-cases/case-1/decision', 'POST', 'decision-key'],
    ['/api/v1/admin/wallet/manual/manual-deposit-cases/case-1/preview', 'POST', undefined],
    ['/api/v1/admin/wallet/manual/manual-deposit-cases/case-1/execute', 'POST', 'operation-1'],
    ['/api/v1/admin/wallet/manual/manual-deposit-cases/operations/operation-1', 'GET', undefined]
  ]);
});

test('repair dialog exposes a separate manual case entry rather than accepting an operator supplied user', () => {
  assert.equal(typeof repairDialog.manualDepositCaseDialog, 'function');
});

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.handlers = {}; this.classList = {add() {}}; this.style = {}; this.value = ''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute() {}
  addEventListener(name, handler) { this.handlers[name] = handler; }
  remove() {}
  focus() {}
  showModal() { this.open = true; }
  close() { this.open = false; this.handlers.close?.(); }
  getBoundingClientRect() { return {left: 0, right: 1, top: 0, bottom: 1}; }
  find(tag) { return [this, ...this.children.filter(child => child instanceof Element).flatMap(child => child.find(tag))].filter(child => child.tag === tag); }
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('manual case flow uses context attribution, records approval, previews, and only then executes', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const calls = [], storage = new Map(), completed = [];
  const api = {
    getManualDepositCaseContext: async () => ({receipt_id: 'receipt-1', txid: 'b'.repeat(64), log_index: 4, amount: '10.000001', asset: 'USDT', user_id: 'system-user', username: 'system-name', nickname: '系统昵称', binding_id: 'binding-1', ordinary_intent_available: false, blockers: []}),
    createManualDepositCase: async (body, options) => { calls.push(['create', body, options]); return {case_id: 'case-1', status: 'PENDING_DECISION', receipt_id: 'receipt-1', user_id: 'system-user', amount: '10.000001'}; },
    decideManualDepositCase: async (id, body, options) => { calls.push(['decision', id, body, options]); return {case_id: id, status: 'APPROVED', receipt_id: 'receipt-1', user_id: 'system-user', amount: '10.000001'}; },
    previewManualDepositCase: async id => { calls.push(['preview', id]); return {preview_id: 'preview-1', digest: 'digest', expected_version: 1, expires_at: '2026-09-13T00:01:30Z', blockers: [], status: 'VALIDATED', confirmation: {receipt_id: 'receipt-1', user_id: 'system-user'}}; },
    executeManualDepositCase: async (id, body, options) => { calls.push(['execute', id, body, options]); return {operation_id: body.operation_id, case_id: id, status: 'EXECUTED', receipt_id: 'receipt-1', user_id: 'system-user', amount: '10.000001', ledger_transaction_id: 'ledger-1'}; }
  };
  manualDepositCaseDialog(api, {txid: 'b'.repeat(64), log_index: 4}, {actorId: 'owner', storage: {getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)}, onCompleted: result => completed.push(result)});
  await settle(); await settle();
  assert.ok(document.body.find('dd').some(node => node.textContent === 'system-user'));
  assert.equal(document.body.find('input').filter(node => node.type !== 'checkbox').length, 0, 'user and amount are never editable');
  let textareas = document.body.find('textarea'); textareas[0].value = '历史绑定与链上收据已核对';
  let check = document.body.find('input').find(node => node.type === 'checkbox'); check.checked = true;
  document.body.find('form')[0].handlers.submit({preventDefault() {}}); await settle(); await settle();
  assert.deepEqual(calls[0][1], {receipt_id: 'receipt-1', user_id: 'system-user', reason_detail: '历史绑定与链上收据已核对', ownership_attestation: true});
  textareas = document.body.find('textarea'); textareas[0].value = '批准依据已复核'; check = document.body.find('input').find(node => node.type === 'checkbox'); check.checked = true;
  document.body.find('button').find(node => node.textContent === '批准补录单').handlers.click(); await settle(); await settle();
  assert.equal(calls[1][2].decision, 'APPROVED');
  assert.equal(calls.some(([name]) => name === 'execute'), false, 'approval does not credit');
  document.body.find('button').find(node => node.textContent === '预检（不入账）').handlers.click(); await settle(); await settle();
  assert.equal(calls[2][0], 'preview');
  check = document.body.find('input').find(node => node.type === 'checkbox'); check.checked = true; check.handlers.change();
  document.body.find('button').find(node => node.textContent === '确认入账').handlers.click(); await settle(); await settle();
  const execute = calls.find(([name]) => name === 'execute');
  assert.equal(execute[1], 'case-1'); assert.equal(execute[2].confirmed, true); assert.equal(execute[3].idempotencyKey, execute[2].operation_id);
  assert.equal(completed.length, 1);
});

test('reopened unknown manual case operation only queries its saved operation and never replays it', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const storage = new Map();
  const key = `chatflow.manual.deposit-case:owner:${'c'.repeat(64)}:2`;
  storage.set(key, JSON.stringify({case_id: 'case-1', operation_id: 'operation-1'}));
  const calls = [];
  manualDepositCaseDialog({
    getManualDepositCaseContext: async () => ({receipt_id: 'receipt-1', txid: 'c'.repeat(64), log_index: 2, user_id: 'system-user', amount: '10.000001', blockers: []}),
    getManualDepositCase: async id => ({case_id: id, status: 'APPROVED', receipt_id: 'receipt-1', user_id: 'system-user'}),
    getManualDepositCaseOperation: async id => { calls.push(['query', id]); const error = new Error('not found'); error.status = 404; throw error; },
    executeManualDepositCase: async () => calls.push(['execute'])
  }, {txid: 'c'.repeat(64), log_index: 2}, {actorId: 'owner', storage: {getItem: value => storage.get(value) ?? null, setItem: (value, body) => storage.set(value, body), removeItem: value => storage.delete(value)}});
  await settle(); await settle(); await settle();
  assert.deepEqual(calls, [['query', 'operation-1']]);
  assert.ok(document.body.find('button').some(node => node.textContent === '重新预检（保留原操作编号）'));
});

test('saved operation is queried before blocked context and an executed case has no decision or write controls', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const storage = new Map(), calls = [];
  const key = `chatflow.manual.deposit-case:owner:${'d'.repeat(64)}:3`;
  storage.set(key, JSON.stringify({case_id: 'case-1', operation_id: 'operation-1'}));
  manualDepositCaseDialog({
    getManualDepositCaseContext: async () => ({receipt_id: 'receipt-1', txid: 'd'.repeat(64), log_index: 3, user_id: 'system-user', blockers: ['EVIDENCE_EXPIRED']}),
    getManualDepositCaseOperation: async id => { calls.push(id); return {operation_id: id, case_id: 'case-1', status: 'EXECUTED', ledger_transaction_id: 'ledger-1'}; },
    getManualDepositCase: async () => { throw Error('must not read case when operation already executed'); }
  }, {txid: 'd'.repeat(64), log_index: 3}, {actorId: 'owner', storage: {getItem: value => storage.get(value) ?? null, setItem() {}, removeItem: value => storage.delete(value)}});
  await settle(); await settle();
  assert.deepEqual(calls, ['operation-1']);
  assert.ok(document.body.find('dd').some(node => node.textContent === 'ledger-1'));
  assert.equal(document.body.find('button').some(node => /批准补录单|确认入账|预检/.test(node.textContent)), false);
});

test('missing or corrupted journal storage closes manual-case writes', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  let contexts = 0;
  manualDepositCaseDialog({getManualDepositCaseContext: async () => { contexts++; return {}; }}, {txid: 'e'.repeat(64), log_index: 1}, {actorId: 'owner', storage: {getItem: () => null}});
  await settle();
  assert.equal(contexts, 0);
  assert.equal(document.body.find('form').length, 0);
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  manualDepositCaseDialog({getManualDepositCaseContext: async () => ({})}, {txid: 'f'.repeat(64), log_index: 1}, {actorId: 'owner', storage: {getItem: () => '{broken', setItem() {}, removeItem() {}}});
  await settle();
  assert.equal(document.body.find('form').length, 0);
});

test('saved manual case without an owner identity cannot expose write controls', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const txid = 'g'.repeat(64), storage = new Map();
  storage.set(`chatflow.manual.deposit-case::${txid}:1`, JSON.stringify({case_id:'case-1'}));
  let reads = 0, decisions = 0;
  manualDepositCaseDialog({getManualDepositCase:async()=>{reads++;return {case_id:'case-1',status:'PENDING_DECISION',receipt_id:'r',user_id:'u'};},decideManualDepositCase:async()=>{decisions++;}}, {txid,log_index:1}, {storage:{getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)}});
  await settle(); await settle();
  assert.equal(reads,0);
  assert.equal(decisions,0);
  assert.equal(document.body.find('form').length,0);
  assert.equal(document.body.find('button').some(node=>/批准补录单|驳回补录单|确认入账|预检/.test(node.textContent)),false);
});

test('unknown create keeps its stable journal and never auto-submits a new key', async () => {
  const store = new Map(), txid = '9'.repeat(64); let creates = 0;
  const storage = {getItem: key => store.get(key) ?? null, setItem: (key, value) => store.set(key, value), removeItem: key => store.delete(key)};
  const api = {getManualDepositCaseContext: async () => ({receipt_id: 'r', txid, log_index: 1, user_id: 'u', amount: '10.000001', blockers: [], cases: []}), createManualDepositCase: async () => { creates++; throw new Error('offline'); }};
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  manualDepositCaseDialog(api, {txid, log_index: 1}, {actorId: 'owner', storage}); await settle(); await settle();
  document.body.find('textarea')[0].value = '依据'; const check = document.body.find('input').find(node => node.type === 'checkbox'); check.checked = true;
  document.body.find('form')[0].handlers.submit({preventDefault() {}}); await settle(); await settle();
  assert.equal(creates, 1); const saved = JSON.parse([...store.values()][0]); assert.equal(saved.stage, 'create'); assert.ok(saved.create_key); assert.equal(saved.payload.user_id, 'u');
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  manualDepositCaseDialog(api, {txid, log_index: 1}, {actorId: 'owner', storage}); await settle(); await settle();
  assert.equal(creates, 1); assert.equal(document.body.find('form').length, 0);
});

test('saved case is read before a credited context blocker and decision never posts when persistence fails', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const txid = '8'.repeat(64), key = `chatflow.manual.deposit-case:owner:${txid}:1`;
  const storage = {getItem: () => JSON.stringify({case_id: 'case-1'}), setItem() { throw Error('quota'); }, removeItem() {}};
  let contexts = 0, decisions = 0;
  manualDepositCaseDialog({getManualDepositCaseContext: async () => { contexts++; return {blockers:['RECEIPT_ALREADY_CREDITED']};}, getManualDepositCase: async () => ({case_id:'case-1',status:'PENDING_DECISION',receipt_id:'r',user_id:'u'}), decideManualDepositCase: async () => { decisions++; }}, {txid,log_index:1}, {actorId:'owner',storage});
  await settle(); await settle();
  assert.equal(contexts, 0); document.body.find('textarea')[0].value='依据'; const check=document.body.find('input').find(node=>node.type==='checkbox'); check.checked=true;
  document.body.find('button').find(node=>node.textContent==='批准补录单').handlers.click(); await settle();
  assert.equal(decisions,0);
});

test('completed credit stays final when the list refresh returns false', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const storage = new Map(), txid = '7'.repeat(64); let executes = 0;
  const api = {
    getManualDepositCaseContext: async () => ({receipt_id:'receipt-1',txid,log_index:1,user_id:'user-1',blockers:[],cases:[]}),
    createManualDepositCase: async () => ({case_id:'case-1',status:'PENDING_DECISION',receipt_id:'receipt-1',user_id:'user-1'}),
    decideManualDepositCase: async () => ({case_id:'case-1',status:'APPROVED',receipt_id:'receipt-1',user_id:'user-1'}),
    previewManualDepositCase: async () => ({preview_id:'preview-1',digest:'digest',expected_version:1,expires_at:'2026-09-13T00:01:30Z',status:'VALIDATED',blockers:[]}),
    executeManualDepositCase: async (_id, body) => { executes++; return {operation_id:body.operation_id,case_id:'case-1',status:'EXECUTED',receipt_id:'receipt-1',ledger_transaction_id:'ledger-1'}; }
  };
  manualDepositCaseDialog(api,{txid,log_index:1},{actorId:'owner',storage:{getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)},onCompleted:()=>false});
  await settle(); await settle();
  document.body.find('textarea')[0].value='创建依据'; let check=document.body.find('input').find(node=>node.type==='checkbox'); check.checked=true;
  document.body.find('form')[0].handlers.submit({preventDefault(){}}); await settle(); await settle();
  document.body.find('textarea')[0].value='批准依据'; check=document.body.find('input').find(node=>node.type==='checkbox'); check.checked=true;
  document.body.find('button').find(node=>node.textContent==='批准补录单').handlers.click(); await settle(); await settle();
  document.body.find('button').find(node=>node.textContent==='预检（不入账）').handlers.click(); await settle(); await settle();
  check=document.body.find('input').find(node=>node.type==='checkbox'); check.checked=true; check.handlers.change();
  document.body.find('button').find(node=>node.textContent==='确认入账').handlers.click(); await settle(); await settle(); await settle();
  assert.equal(executes,1);
  assert.match(document.body.find('p')[0].textContent,/已入账；列表刷新失败，请手动刷新/);
});

test('unknown create retry uses its saved key once while the request is pending', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const txid='6'.repeat(64), key=`chatflow.manual.deposit-case:owner:${txid}:1`, storage=new Map();
  storage.set(key,JSON.stringify({stage:'create',create_key:'stable-create-key',payload:{receipt_id:'receipt-1',user_id:'user-1',reason_detail:'依据',ownership_attestation:true}}));
  let creates=0, resolve;
  manualDepositCaseDialog({getManualDepositCaseContext:async()=>({receipt_id:'receipt-1',txid,log_index:1,user_id:'user-1',blockers:[],cases:[]}),createManualDepositCase:async(_body,options)=>{creates++;assert.equal(options.idempotencyKey,'stable-create-key');return new Promise(done=>{resolve=done;});}}, {txid,log_index:1}, {actorId:'owner',storage:{getItem:value=>storage.get(value)??null,setItem:(name,value)=>storage.set(name,value),removeItem:name=>storage.delete(name)}});
  await settle(); await settle();
  const retry=document.body.find('button').find(node=>node.textContent==='查询并重试原创建请求'); retry.handlers.click(); retry.handlers.click(); await settle();
  assert.equal(creates,1);
  resolve({case_id:'case-1',status:'PENDING_DECISION',receipt_id:'receipt-1',user_id:'user-1'}); await settle(); await settle();
});

test('case selection query failure is handled in the dialog and can be retried', async () => {
  globalThis.document = {body: new Element('body'), createElement: tag => new Element(tag)};
  const txid='5'.repeat(64), storage=new Map();
  manualDepositCaseDialog({getManualDepositCaseContext:async()=>({receipt_id:'receipt-1',txid,log_index:1,user_id:'user-1',blockers:[],cases:[{case_id:'case-1',status:'PENDING_DECISION'}]}),getManualDepositCase:async()=>{throw Error('offline');}}, {txid,log_index:1}, {actorId:'owner',storage:{getItem:value=>storage.get(value)??null,setItem:(name,value)=>storage.set(name,value),removeItem:name=>storage.delete(name)}});
  await settle(); await settle();
  await assert.doesNotReject(async()=>document.body.find('button').find(node=>node.textContent.includes('case-1')).handlers.click());
  assert.match(document.body.find('p')[0].textContent,/读取补录单失败：offline/);
  assert.ok(document.body.find('button').some(node=>node.textContent==='再次查询补录单'));
});

test('approval double click posts exactly one decision', async () => {
  globalThis.document={body:new Element('body'),createElement:tag=>new Element(tag)};
  const txid='4'.repeat(64), storage=new Map(); let decisions=0, resolve;
  manualDepositCaseDialog({getManualDepositCaseContext:async()=>({receipt_id:'r',txid,log_index:1,user_id:'u',blockers:[],cases:[]}),createManualDepositCase:async()=>({case_id:'case-1',status:'PENDING_DECISION',receipt_id:'r',user_id:'u'}),decideManualDepositCase:async()=>{decisions++;return new Promise(done=>{resolve=done;});}}, {txid,log_index:1}, {actorId:'owner',storage:{getItem:key=>storage.get(key)??null,setItem:(key,value)=>storage.set(key,value),removeItem:key=>storage.delete(key)}});
  await settle(); await settle(); document.body.find('textarea')[0].value='创建'; let check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;document.body.find('form')[0].handlers.submit({preventDefault(){}});await settle();await settle();
  document.body.find('textarea')[0].value='批准';check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;const approve=document.body.find('button').find(node=>node.textContent==='批准补录单');approve.handlers.click();approve.handlers.click();await settle();assert.equal(decisions,1);
  resolve({case_id:'case-1',status:'APPROVED',receipt_id:'r',user_id:'u'});await settle();await settle();
});

test('rejected case reopens context before offering a new case', async () => {
  globalThis.document={body:new Element('body'),createElement:tag=>new Element(tag)};
  const txid='3'.repeat(64), key=`chatflow.manual.deposit-case:owner:${txid}:1`, storage=new Map();storage.set(key,JSON.stringify({case_id:'case-1'}));let contexts=0;
  manualDepositCaseDialog({getManualDepositCase:async()=>({case_id:'case-1',status:'REJECTED',receipt_id:'r',user_id:'u'}),getManualDepositCaseContext:async()=>{contexts++;return {receipt_id:'r',txid,log_index:1,user_id:'u',blockers:[],cases:[]};}}, {txid,log_index:1}, {actorId:'owner',storage:{getItem:name=>storage.get(name)??null,setItem:(name,value)=>storage.set(name,value),removeItem:name=>storage.delete(name)}});
  await settle();await settle();document.body.find('button').find(node=>node.textContent==='创建新的补录单').handlers.click();await settle();await settle();
  assert.equal(contexts,1);assert.equal(document.body.find('form').length,1);
});

test('operation 404 re-previews and keeps the original operation id for execute', async () => {
  globalThis.document={body:new Element('body'),createElement:tag=>new Element(tag)};
  const txid='2'.repeat(64), key=`chatflow.manual.deposit-case:owner:${txid}:1`, storage=new Map();storage.set(key,JSON.stringify({case_id:'case-1',operation_id:'operation-1'}));let executed;
  manualDepositCaseDialog({getManualDepositCaseOperation:async()=>{const error=Error('not found');error.status=404;throw error;},getManualDepositCase:async()=>({case_id:'case-1',status:'APPROVED',receipt_id:'r',user_id:'u'}),previewManualDepositCase:async()=>({preview_id:'preview-1',digest:'digest',expected_version:1,expires_at:'2026-09-13T00:01:30Z',status:'VALIDATED',blockers:[]}),executeManualDepositCase:async(_case,body)=>{executed=body;return {status:'SUBMITTED'};}}, {txid,log_index:1}, {actorId:'owner',storage:{getItem:name=>storage.get(name)??null,setItem:(name,value)=>storage.set(name,value),removeItem:name=>storage.delete(name)}});
  await settle();await settle();document.body.find('button').find(node=>node.textContent==='重新预检（保留原操作编号）').handlers.click();await settle();await settle();
  const check=document.body.find('input').find(node=>node.type==='checkbox');check.checked=true;check.handlers.change();document.body.find('button').find(node=>node.textContent==='确认入账').handlers.click();await settle();await settle();
  assert.equal(executed.operation_id,'operation-1');
});
