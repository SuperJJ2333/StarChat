// Chain evidence is displayed briefly but retained intact for explicit copy and lookup.
export const shortHash = txid => typeof txid === 'string' && /^[a-f0-9]{64}$/i.test(txid)
  ? `${txid.slice(0,8)}…${txid.slice(-6)}` : '哈希不可用';

export const shortChainValue = value => typeof value === 'string' && value.length > 20
  ? `${value.slice(0,8)}…${value.slice(-6)}` : value || '暂无';

export const transferKey = item => `${item.txid} / ${item.log_index}`;

export const formatUsdtUnits = units => {
  if (typeof units !== 'string' && typeof units !== 'bigint') return '—';
  const raw=String(units);
  if (!/^\d+$/.test(raw)) return '—';
  const padded=raw.padStart(7,'0');
  return `${padded.slice(0,-6)}.${padded.slice(-6)}`;
};

const chainFields=['txid','log_index','timestamp_ms','block_number','amount','net_amount','direction',
  'era','asset','network','user_attribution','ledger_status','watch_only'];
const associationFields=['kind','record_id','ledger_status','user_id','ledger_transaction_id','intent_id',
  'reason_code','evidence_status','attribution_status','attribution_reason_text','user_username','user_nickname'];
const summaryFields=['source','network','asset','watch_only','financial_writes_enabled','user_attribution',
  'independent_verification','coverage_complete','coverage_meaning','coverage_start_ms','live_started_ms',
  'checkpoint_ms','heartbeat_ms','last_success_ms','lag_ms','freshness_ms','observer_status',
  'reconciliation','balance','total'];
const primitive=value=>value===null||typeof value==='boolean'||
  (typeof value==='string'&&value.length<=2048)||
  (typeof value==='number'&&Number.isSafeInteger(value));
function project(source,keys) {
  if(!source||typeof source!=='object'||Array.isArray(source))return null;
  const result={};
  for(const key of keys){
    const value=source[key];
    if(value===undefined)continue;
    if(!primitive(value))return null;
    result[key]=value;
  }
  return result;
}
function chainItem(source,detail=false) {
  const item=project(source,detail?[...chainFields,'from_address','to_address']:chainFields);
  if(!item||!_validHash(item.txid)||!Number.isSafeInteger(item.log_index)||item.log_index<0||
      !Number.isSafeInteger(item.timestamp_ms)||item.timestamp_ms<0||
      !/^\d+\.\d{6}$/.test(item.amount)||!['INFLOW','UNMATCHED_OUTFLOW'].includes(item.direction)||
      item.asset!=='USDT')return null;
  if(detail&&(typeof item.from_address!=='string'||typeof item.to_address!=='string'))return null;
  if(source.platform_record!==undefined&&source.platform_record!==null){
    const link=project(source.platform_record,associationFields);
    if(!link)return null;
    item.platform_record=link;
  }
  return item;
}
const _validHash=value=>typeof value==='string'&&/^[a-f0-9]{64}$/i.test(value);
function filters(source,draft){
  if(!source||typeof source!=='object'||Array.isArray(source))return null;
  const result={};
  for(const key of draft?['direction','txid','start','end']:['direction','txid','start_ms','end_ms']){
    const value=source[key];
    if(value===undefined)continue;
    if(draft||key==='direction'||key==='txid'){
      if(typeof value!=='string'||value.length>128)return null;
    }else if(value!==null&&(!Number.isSafeInteger(value)||value<0))return null;
    result[key]=value;
  }
  if(result.direction!==undefined&&!['','INFLOW','UNMATCHED_OUTFLOW'].includes(result.direction))return null;
  if(!draft&&result.txid&&!_validHash(result.txid))return null;
  return result;
}

// A short-lived menu view is ordinary bounded data; unknown keys never enter the cache.
export function validateChainReadView(source) {
  const pageSize=source?.pageSize??25;
  if(![10,20,25,50].includes(pageSize)||!source||typeof source!=='object'||Array.isArray(source)||
      !Array.isArray(source.items)||source.items.length>pageSize||
      !Number.isSafeInteger(source.offset)||source.offset<0||source.offset>1_000_000||source.offset%pageSize!==0||
      !Number.isSafeInteger(source.total)||source.total<source.offset+source.items.length||
      !Number.isSafeInteger(source.snapshot)||source.snapshot<0||
      !Number.isSafeInteger(source.cachedAt)||source.cachedAt<0)return null;
  const draftFilters=filters(source.draftFilters,true),activeFilters=filters(source.activeFilters,false);
  const summary=project(source.summary,summaryFields);
  if(!draftFilters||!activeFilters||!summary)return null;
  const items=source.items.map(item=>chainItem(item));
  if(items.some(item=>!item))return null;
  const pageScrollY=source.pageScrollY,scrollLeft=source.scrollLeft;
  if(typeof pageScrollY!=='number'||!Number.isFinite(pageScrollY)||pageScrollY<0||pageScrollY>1e9||
      typeof scrollLeft!=='number'||!Number.isFinite(scrollLeft)||scrollLeft<0||scrollLeft>1e9)return null;
  let detail;
  if(source.detail!==undefined&&source.detail!==null){
    if(!source.detail.open)return null;
    const item=chainItem(source.detail.item),record=chainItem(source.detail.record,true);
    if(!item||!record||item.txid.toLowerCase()!==record.txid.toLowerCase()||
        item.log_index!==record.log_index)return null;
    detail={item,record,open:true};
  }
  return {...(source.pageSize!==undefined?{pageSize}:{}),draftFilters,activeFilters,offset:source.offset,snapshot:source.snapshot,items,summary,total:source.total,
    pageScrollY,scrollLeft,...(detail?{detail}:{}),cachedAt:source.cachedAt};
}
