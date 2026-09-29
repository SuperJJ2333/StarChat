import test from 'node:test';
import assert from 'node:assert/strict';

let view;
try { view = await import('../src/admin-chain-view-state.js'); }
catch (error) { if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error; view = {}; }

const txid = '0123456789abcdef'.repeat(4);

test('shortHash keeps only the ends of a canonical transaction hash', () => {
  assert.equal(view.shortHash?.(txid), '01234567…abcdef');
  assert.equal(view.shortHash?.('not-a-hash'), '哈希不可用');
});

test('transferKey retains the complete transaction hash and exact log index', () => {
  assert.equal(view.transferKey?.({txid, log_index: 7}), `${txid} / 7`);
});

test('USDT units format exactly as six decimal places beyond safe Number range', () => {
  assert.equal(view.formatUsdtUnits?.('0'), '0.000000');
  assert.equal(view.formatUsdtUnits?.('1'), '0.000001');
  assert.equal(view.formatUsdtUnits?.('9007199254740993'), '9007199254.740993');
  assert.equal(view.formatUsdtUnits?.('1.5'), '—');
  assert.equal(view.formatUsdtUnits?.(9007199254740993), '—');
});

test('read view validation bounds one page, keeps only known chain fields and rejects corrupt detail',()=>{
  const item={txid,log_index:7,timestamp_ms:1780000000000,amount:'1.000001',direction:'UNMATCHED_OUTFLOW',
    asset:'USDT',platform_record:{kind:'PAYOUT',ledger_status:'REVIEW',secret_token:'do-not-copy'},secret_token:'do-not-copy'};
  const read={draftFilters:{direction:'UNMATCHED_OUTFLOW',txid,start:'2026-09-29T08:00',end:''},
    activeFilters:{direction:'UNMATCHED_OUTFLOW',txid,start_ms:1780000000000,end_ms:undefined},
    offset:25,snapshot:44,items:[item],summary:{balance:'1.000001',last_success_ms:1780000000000,
      observer_status:'OK',secret_token:'do-not-copy'},total:51,pageScrollY:222,scrollLeft:12,
    detail:{item,record:{...item,to_address:'T-recipient',from_address:'T-official'},open:true},cachedAt:1780000000100,
    access_token:'do-not-copy'};
  const safe=view.validateChainReadView?.(read);
  assert.ok(safe);assert.equal(safe.offset,25);assert.equal(safe.detail.open,true);
  assert.equal(JSON.stringify(safe).includes('do-not-copy'),false);
  assert.equal(view.validateChainReadView?.({...read,items:Array.from({length:26},()=>item)}),null);
  assert.equal(view.validateChainReadView?.({...read,detail:{...read.detail,record:{...item,log_index:8}}}),null);
  assert.equal(view.validateChainReadView?.({...read,offset:-1}),null);
  const earlierItem={...item,log_index:6};
  assert.ok(view.validateChainReadView?.({...read,items:[earlierItem]}),
    'a still-open detail read from an earlier page may be kept separately from the visible page');
});
