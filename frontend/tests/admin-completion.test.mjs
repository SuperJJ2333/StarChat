import test from 'node:test';
import assert from 'node:assert/strict';
import {ledgerLabels, ledgerFilters} from '../src/admin-ledger-panel.js';
import {createAdminApi} from '../src/admin-api.js';

test('ledger scene and distribution stay separate and missing reason is explicit',()=>{
  assert.deepEqual(ledgerLabels({scene:'GROUP',mode:'RANDOM',reason_text:'发出红包',anomalies:[]}),['群聊红包 · 手气红包','发出红包']);
  assert.equal(ledgerLabels({scene:'OTHER',mode:'OTHER',anomalies:['MISSING_REASON']})[1],'原因待补充（异常数据）');
  assert.throws(()=>ledgerFilters({start_at:'2026-09-10T10:00',end_at:'2026-09-09T10:00'}));
  assert.equal(ledgerFilters({start_at:'2026-09-10T08:00'}).start_at,'2026-09-10T00:00:00.000Z');
});
test('ledger API preserves combined search and cursor, no email response assumptions',async()=>{
  let path;
  const api=createAdminApi({fetchImpl:async p=>{path=p;return {ok:true,json:async()=>({items:[]})};}});
  await api.getLedgerEntries({username:'chat',nickname:'小明',email:'a@b',scene:'GROUP',mode:'RANDOM',cursor:'bound'});
  const params=new URL(path,'https://local.test').searchParams;
  for(const [key,value] of Object.entries({username:'chat',nickname:'小明',email:'a@b',scene:'GROUP',mode:'RANDOM',cursor:'bound'}))assert.equal(params.get(key),value);
});
