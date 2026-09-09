import test from 'node:test';
import assert from 'node:assert/strict';
import {processIncident, incidentSummary, incidentError, diagnosticSummary, fundControlError} from '../src/wallet-incident-workflow.js';
import {operationJournal} from '../src/admin-manual-wallet-panel.js';

const digest='a'.repeat(64);
function fixture(start={}) {
  let current={id:'incident',status:'OPEN',version:1,condition_active:true,code:'MANUAL_SOURCE_UNHEALTHY',...start};
  const data=new Map(),calls=[];
  const journal=operationJournal({getItem:k=>data.get(k)??null,setItem:(k,v)=>data.set(k,v),removeItem:k=>data.delete(k)},'owner');
  const api={getWalletIncident:async()=>({...current}),manualWalletIncidentAction:async(id,kind,body,options)=>{
    calls.push({kind,body:{...body},options});
    assert.equal(body.expected_version,current.version);
    current={...current,version:current.version+1,status:kind==='resolve'?'RESOLVED':'ACKNOWLEDGED',...(kind==='review'?{condition_active:false,clearance_digest:digest}:{})};
    return {...current};
  }};
  return {api,journal,calls,data,get current(){return current;},set current(value){current=value;}};
}
const run=f=>processIncident({id:'incident',api:f.api,journal:f.journal,credentials:{operation_password:'synthetic-secret'},authMode:'operation_password'});
test('legacy version-keyed pending review retains exact metadata and idempotency key',async()=>{
  const f=fixture({status:'ACKNOWLEDGED',version:4});
  const old=f.journal.begin('incident:incident:review:4',{reason_code:'MANUAL_REVIEW',expected_version:4});
  await run(f);assert.equal(f.calls[0].options.idempotencyKey,old.key);assert.equal(f.calls[0].body.reason_code,'MANUAL_REVIEW');assert.equal(f.data.size,0);
});
test('one password processes ack review resolve with latest state and never resumes money',async()=>{
  const f=fixture(); const result=await run(f);
  assert.equal(result.status,'resolved');assert.deepEqual(f.calls.map(x=>x.kind),['ack','review','resolve']);
  assert.deepEqual(f.calls.map(x=>x.body.expected_version),[1,2,3]);
  assert.equal(f.calls[2].body.clearance_digest,digest);assert.equal(f.data.size,0);
  assert.equal(new Set(f.calls.map(x=>x.options.idempotencyKey)).size,3);
  await run(f);assert.equal(f.calls.length,3);
});
test('unknown outcome stops, retains original per-step key across version changes and explicit retry',async()=>{
  const f=fixture(), original=f.api.manualWalletIncidentAction;
  let lost=true;
  f.api.manualWalletIncidentAction=async(...args)=>{if(lost){f.calls.push({kind:args[1],body:args[2],options:args[3]});throw {code:'NETWORK_ERROR'};}return original(...args);};
  await assert.rejects(run(f));assert.equal(f.calls.length,1);assert.equal(f.data.size,1);
  const stored=JSON.stringify([...f.data]);assert.ok(!stored.includes('synthetic-secret'));
  lost=false;await run(f);assert.equal(f.calls[0].options.idempotencyKey,f.calls[1].options.idempotencyKey);
});
test('only definite version conflicts allow bounded preparation of another key',async()=>{
  const f=fixture();f.api.manualWalletIncidentAction=async(id,kind,body,options)=>{f.calls.push({kind,body,options});f.current={...f.current,version:f.current.version+1};throw {code:'WALLET_INCIDENT_VERSION_CONFLICT'};};
  await assert.rejects(run(f),e=>e.code==='WALLET_INCIDENT_VERSION_CONFLICT');
  assert.equal(f.calls.length,3);assert.equal(f.data.size,0);
  assert.deepEqual(f.calls.map(x=>x.body.expected_version),[1,2,3]);
});
test('TOTP performs only one step then requires a fresh code even after conflict',async()=>{
  const f=fixture();const credentials={mfa_proof:'123456'};
  const result=await processIncident({id:'incident',api:f.api,journal:f.journal,credentials,authMode:'totp'});
  assert.equal(result.status,'needs_credential');assert.deepEqual(f.calls.map(x=>x.kind),['ack']);assert.equal(credentials.mfa_proof,undefined);
  f.api.manualWalletIncidentAction=async()=>{f.calls.push({kind:'conflict'});throw {code:'WALLET_INCIDENT_VERSION_CONFLICT'};};
  const next=await processIncident({id:'incident',api:f.api,journal:f.journal,credentials:{mfa_proof:'654321'},authMode:'totp'});
  assert.equal(next.status,'needs_credential');assert.equal(f.calls.length,2);
});
test('credentials erased on all outcomes; active condition after review prevents resolve',async()=>{
  const f=fixture({status:'ACKNOWLEDGED'}),credentials={operation_password:'synthetic-secret'};
  f.api.manualWalletIncidentAction=async()=>({...f.current,version:2});
  const result=await processIncident({id:'incident',api:f.api,journal:f.journal,credentials,authMode:'operation_password'});
  assert.equal(result.status,'blocked');assert.deepEqual(credentials,{});
});
test('presentation distinguishes historical incidents and exact nonblocking backing advisory',()=>{
  const item={code:'MANUAL_BACKING_DEFICIT',severity:'P1',fingerprint:'manual-liquidity:backing-deficit',subject_id:'global',status:'OPEN',condition_active:true};
  assert.equal(incidentSummary(item,'manual_liquidity').advisory,true);
  assert.equal(incidentSummary({...item,fingerprint:'other'},'manual_liquidity').advisory,false);
  assert.equal(incidentSummary(item,'other').advisory,false);
  assert.match(incidentSummary({status:'ACKNOWLEDGED',condition_active:false}).condition,/异常已消失/);
  assert.match(incidentSummary({status:'ACKNOWLEDGED',condition_active:true}).condition,/尚未通过异常消除复核/);
});
test('incident explanation describes its meaning without inventing an exact historical cause',()=>{
  const source=incidentSummary({code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',condition_active:true});
  assert.match(source.explanation,/链上数据未满足健康要求/);
  assert.match(source.explanation,/可能/);assert.match(source.explanation,/具体历史触发条件以记录为准/);
  assert.doesNotMatch(source.explanation,/已确认超时|资金丢失|资金被盗/);
  assert.match(incidentSummary({code:'MANUAL_RESERVE_STALE'}).explanation,/证据/);
  assert.match(incidentSummary({code:'MANUAL_BACKING_DEFICIT'}).explanation,/储备/);
  assert.match(incidentSummary({code:'UNKNOWN_PRIVATE_DETAIL'}).explanation,/未记录/);
});
test('specific safe monitor guidance and unknown incident outcome never use payment warnings or provider text',()=>{
  const message=incidentError({code:'WALLET_MONITOR_UNAVAILABLE',fields:[{type:'wallet.monitor.reason',msg:'MANUAL_COVERAGE_PENDING'},{type:'wallet.monitor.reason',msg:'secret-provider-url'}]});
  assert.match(message,/等待业务流水同步/);assert.doesNotMatch(message,/secret|禁止重复付款/);
  assert.match(incidentError({code:'NETWORK_ERROR'}),/先刷新/);
  assert.doesNotMatch(incidentError({message:'secret-provider-url'}),/secret|付款/);
  assert.match(diagnosticSummary({source_status:'HEALTHY',coverage_status:'WAITING'}),/链上数据正常.*等待业务流水同步/);
});
test('all server allowlisted reasons have specific actionable Chinese explanations',async()=>{
  const {readFile}=await import('node:fs/promises');
  const backend=await readFile(new URL('../../services/business-api/app/modules/wallet/manual_diagnostics.py',import.meta.url),'utf8');
  const codes=backend.match(/MONITOR_REASONS = frozenset\('''([\s\S]*?)'''/)[1].trim().split(/\s+/);
  for(const code of codes){
    const message=incidentError({code:'WALLET_MONITOR_UNAVAILABLE',fields:[{type:'wallet.monitor.reason',msg:code}]});
    assert.doesNotMatch(message,/本轮检查未完成/,code);assert.doesNotMatch(message,/资金状态未改变/,code);
  }
});
test('untrusted fields cannot throw while explaining an error',()=>{
  assert.doesNotThrow(()=>incidentError({code:'WALLET_MONITOR_UNAVAILABLE',fields:{bad:true}}));
});
test('fund recovery explains other restrictions, unclear ownership and outstanding payouts',()=>{
  assert.match(fundControlError({code:'MANUAL_CONTROL_OTHER_SAFETY_RESTRICTION'}),/其他风控限制/);
  assert.match(fundControlError({code:'MANUAL_CONTROL_PAUSE_SOURCE_UNKNOWN'}),/来源不明/);
  assert.match(fundControlError({code:'MANUAL_CONTROL_UNRESOLVED_PAYOUT'}),/出款/);
});
test('unknown response or a failed fresh read stops later steps and clears credentials',async()=>{
  for(const invalidReply of [true,false]){
    const f=fixture(),credentials={operation_password:'synthetic-secret'};let writes=0,reads=0;
    const get=f.api.getWalletIncident;
    f.api.getWalletIncident=async()=>{reads++;if(!invalidReply&&reads===2)throw {code:'NETWORK_ERROR'};return get();};
    f.api.manualWalletIncidentAction=async()=>{writes++;return invalidReply?{}:{...f.current,status:'ACKNOWLEDGED',version:2};};
    await assert.rejects(processIncident({id:'incident',api:f.api,journal:f.journal,credentials,authMode:'operation_password'}));
    assert.equal(writes,1);assert.deepEqual(credentials,{});assert.equal(f.data.size,invalidReply?1:0);
  }
});
