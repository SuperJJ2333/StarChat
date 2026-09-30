import test from 'node:test';
import assert from 'node:assert/strict';
import {manualWalletPanel, operationJournal, exactUsdt} from '../src/admin-manual-wallet-panel.js';
class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.style={}; this.handlers={}; this.value=''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  setAttribute(name,value) { this[name]=value; }
  addEventListener(name,fn) { this.handlers[name]=fn; }
  remove() { this.removed=true; }
  focus() {}
  showModal() { this.open=true; }
  close() { this.open=false; this.handlers.close?.(); }
  getBoundingClientRect() { return {left:0,right:1,top:0,bottom:1}; }
  find(tag) { return [this,...this.children.flatMap(c=>c.find(tag))].filter(c=>c.tag===tag); }
}
const settle=()=>new Promise(r=>setImmediate(r));

test('void preview expired login offers modal authentication without a write',async()=>{
 let writes=0;
 const panel=setup({
  getManualPayout:async()=>({...order,status:'UNKNOWN',version:1,claimed_by:'owner'}),
  getVoidUnbroadcastPreview:async()=>{throw {status:401,code:'RECENT_LOGIN_REQUIRED'};},
  voidUnbroadcastPayout:async()=>{writes++;}
 },{onReauthenticate:async()=>true});
 await settle();await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 const dialogs=globalThis.document.body.find('dialog').filter(n=>n.open);
 assert.equal(dialogs.length,1);
 assert.ok(dialogs[0].find('button').some(n=>n.textContent==='重新登录'));
 assert.equal(writes,0);
});

test('server wallet grant omits repeated proof while keeping confirmation and original pending key',async()=>{
 const calls=[],store=storage();
 const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'ACTIVE',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async(kind,body,options)=>{calls.push({body,options});throw {code:'NETWORK_ERROR'};}},{walletAccess:true,storage:store});
 await settle();const form=panel.find('form').find(x=>x.name==='control-pause');
 assert.deepEqual(form.find('input').map(x=>x.name),['confirm_pause']);
 await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,0);
 form.find('input')[0].checked=true;await form.handlers.submit({preventDefault(){}});
 await panel.refresh();assert.equal(calls.length,1);
 const restored=panel.find('form').find(x=>x.name==='control-pause');restored.find('input')[0].checked=true;await restored.handlers.submit({preventDefault(){}});
 assert.equal(calls[0].options.idempotencyKey,calls[1].options.idempotencyKey);
 assert.ok(!('operation_password' in calls[0].body));assert.ok(!('mfa_proof' in calls[0].body));
});

test('wallet detail expiration candidate history and refresh status display complete Beijing dates',async()=>{
 const dated={...order,snapshot:{...order.snapshot,expires_at:'2026-09-09T17:02:03Z'},
  candidates:[{txid:'candidate',actor_id:'owner',reason_code:'CHECK',created_at:'2026-09-09T18:04:05Z'}]};
 const panel=setup({getManualPayout:async()=>dated});
 await settle();await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 const values=panel.find('dd').map(n=>n.textContent);
 assert.ok(values.includes('2026-09-10 01:02:03'));
 assert.ok(values.includes('2026-09-10 02:04:05'));
 assert.ok(!values.includes('2026-09-09T17:02:03Z'));
 await panel.refresh();
 assert.ok(panel.find('p').some(n=>/(?:已刷新|部分数据刷新失败) · \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(n.textContent)));
 assert.equal(dated.snapshot.expires_at,'2026-09-09T17:02:03Z');
 assert.equal(dated.candidates[0].created_at,'2026-09-09T18:04:05Z');
});

test('current status check is read-only and requires no operation credential',async()=>{
 let reads=0;
 const panel=setup({getManualWalletDiagnostics:async()=>{reads++;return {source_status:'HEALTHY',coverage_status:'CURRENT'};},getManualWalletControl:async()=>({epoch:1,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),manualWalletIncidentAction:async()=>assert.fail('read must not mutate')});
 await settle();const before=reads;
 const button=panel.find('button').find(x=>x.textContent==='检查当前状态');assert.ok(button);
 await button.handlers.click();assert.ok(reads>before);
 assert.ok(panel.find('p').some(x=>x.textContent?.includes('无需操作密码')));
});

test('pause uses Chinese confirmation and retains original journal reason after response loss',async()=>{
 const store=storage(),calls=[];operationJournal(store,'owner').begin('control:pause:3',{expected_epoch:3,snapshot_digest:digest,reason_code:'EXISTING_REASON'});
 const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'ACTIVE',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async(kind,body)=>{calls.push(body);throw {code:'NETWORK_ERROR'};}},{storage:store});
 await settle();const form=panel.find('form').find(x=>x.name==='control-pause');
 assert.deepEqual(form.find('input').map(x=>x.name),['confirm_pause','mfa_proof']);
 form.find('input')[1].value='123456';await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,0);
 form.find('input')[0].checked=true;form.find('input')[1].value='123456';await form.handlers.submit({preventDefault(){}});
 assert.equal(calls[0].reason_code,'EXISTING_REASON');
});

test('refresh during a command waits and coalesces without replaying the command',async()=>{
 let release,calls=0,reads=0;
 const panel=setup({getManualWalletDiagnostics:async()=>{reads++;return {};},getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async()=>{calls++;await new Promise(r=>release=r);throw {code:'NETWORK_ERROR'};}});
 await settle();const before=reads,form=panel.find('form').find(x=>x.name==='control-resume');form.find('input')[0].checked=true;form.find('input')[1].value='123456';
 const submit=form.handlers.submit({preventDefault(){}});await settle();let finished=false;
 const first=panel.refresh().then(()=>finished=true),second=panel.refresh();await settle();
 assert.equal(finished,false);assert.equal(reads,before);assert.ok(panel.find('p').some(x=>x.textContent?.includes('完成后自动刷新')));
 release();await Promise.all([submit,first,second]);assert.equal(reads,before+1);assert.equal(calls,1);
});

test('new pause records fixed reason and disposal releases waiting refresh without another read',async()=>{
 let release,body,reads=0;
 const panel=setup({getManualWalletDiagnostics:async()=>{reads++;return {};},getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'ACTIVE',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async(kind,value)=>{body=value;await new Promise(r=>release=r);throw {code:'NETWORK_ERROR'};}});
 await settle();const form=panel.find('form').find(x=>x.name==='control-pause');form.find('input')[0].checked=true;form.find('input')[1].value='123456';
 const submit=form.handlers.submit({preventDefault(){}});await settle();assert.equal(body.reason_code,'OWNER_CONTROL_PAUSE');
 const before=reads,pending=panel.refresh();panel.dispose();assert.equal(await pending,false);release();await submit;assert.equal(reads,before);
});

test('simple incident form accepts one password and confirmation, explains history, and never resumes funds',async()=>{
 let incident={id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true,opened_at:'2026-09-08T09:08:55Z'};
 const calls=[],store=storage();
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:true,version:1}),
  getWalletIncidents:async()=>({items:[incident]}),getWalletIncident:async()=>incident,
  getManualWalletDiagnostics:async()=>({source_status:'HEALTHY',coverage_status:'CURRENT',checked_at:'2026-09-08T15:01:00Z'}),
  manualWalletIncidentAction:async(id,kind,body)=>{calls.push(kind);incident={...incident,status:kind==='resolve'?'RESOLVED':'ACKNOWLEDGED',version:incident.version+1,...(kind==='review'?{condition_active:false,clearance_digest:digest}:{})};return incident;},
  manualWalletControlAction:async()=>assert.fail('incident action cannot resume money')},{storage:store});
 await settle();await panel.find('button').find(x=>x.textContent==='查看事故').handlers.click();
 const form=document.body.find('form').find(x=>x.name==='incident-process');assert.ok(form);
 assert.equal(document.body.find('form').filter(x=>x.name.startsWith('incident-')).length,1);
 assert.deepEqual(form.find('input').map(x=>x.name),['accept_incident','operation_password']);
 assert.equal(form.find('input')[0]['aria-label'],'我确认处理这起事故；完成后可前往“资金启停”恢复资金');
 assert.ok(document.body.find('details').some(x=>x.find('summary').some(x=>x.textContent==='技术详情与时间线')));
 assert.ok(document.body.find('dd').some(x=>x.textContent?.includes('17:08:55')));
 assert.ok(panel.find('p').some(x=>x.textContent?.includes('链上数据正常')));
 assert.ok(document.body.find('p').some(x=>x.textContent?.includes('当时链上数据未满足健康要求')));
 form.find('input')[0].checked=true;form.find('input')[1].value='synthetic-password';
 await form.handlers.submit({preventDefault(){}});
 assert.deepEqual(calls,['ack','review','resolve']);assert.equal(form.find('input')[1].value,'');
 assert.ok(!JSON.stringify([...store.data]).includes('synthetic-password'));
});

test('wallet command intent verifies first and never replays the command after grant arrives',async()=>{
 let authorized=false,prompts=0,writes=0;
 const accessController={canWrite:()=>authorized,requestWriteGrant:async()=>{prompts++;return false;}};
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:true,version:1}),
  getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'RUNNING',restriction_scopes:[],unresolved_incidents:0}),
  manualWalletControlAction:async()=>{writes++;throw {code:'NETWORK_ERROR'};}},{walletAccess:true,accessController});
 await settle();const form=panel.find('form').find(x=>x.name==='control-pause');
 form.find('input')[0].checked=true;await form.handlers.submit({preventDefault(){}});
 assert.equal(prompts,1);assert.equal(writes,0);
 authorized=true;await settle();assert.equal(writes,0);
 await form.handlers.submit({preventDefault(){}});assert.equal(writes,1);
});

test('owner can set operation password with independent credentials before a wallet grant',async()=>{
 let writes=0;
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:false,version:0}),
  setWalletOperationPassword:async()=>{writes++;return {version:1};}},{walletAccess:true,accessController:{canWrite:()=>false,requestWriteGrant:async()=>assert.fail('credential setup must not ask for a grant')}});
 await settle();const form=panel.find('form').find(x=>x.name==='operation-password');
 for(const input of form.find('input'))input.value=input.name==='login_password'?'synthetic-login-password':'synthetic-new-operation-password';
 await form.handlers.submit({preventDefault(){}});assert.equal(writes,1);
});

test('T2 is a literal incident filter and detail level while an independent pause remains visible',async()=>{
  const item={id:'temporary-source',code:'MANUAL_SOURCE_UNAVAILABLE',fingerprint:'manual-reserve:MANUAL_SOURCE_UNAVAILABLE',subject_id:'global',severity:'T2',status:'OPEN',version:1,condition_active:true};
  const requests=[];
  const panel=setup({getWalletIncidents:async filters=>{requests.push(filters);return {items:[item]};},getWalletIncident:async()=>item,
    getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:['manual_tron'],unresolved_incidents:0})});
  await settle();
  const form=panel.find('form').find(n=>n.name==='monitoring-filters');
  const severity=form.find('select').find(n=>n['aria-label']==='事故等级');
  assert.deepEqual(severity.find('option').map(n=>n.value),['','P0','P1','T2']);
  severity.value='T2';await form.find('button').find(n=>n.textContent==='查询').handlers.click();
  assert.equal(requests.at(-1).severity,'T2');
  assert.ok(panel.find('td').some(n=>n.textContent==='T2'));
  assert.ok(panel.find('td').some(n=>n.textContent?.includes('记录保留、邮件告警，不会因这条记录自动暂停')));
  assert.ok(panel.find('p').some(n=>n.textContent?.includes('资金已暂停')));
  await panel.find('button').find(n=>n.textContent==='查看事故').handlers.click();
  assert.ok(document.body.find('dd').some(n=>n.textContent==='T2'));
  assert.ok(document.body.find('p').some(n=>n.textContent?.includes('链上数据暂不可用')));
  assert.ok(document.body.find('dd').some(n=>n.textContent?.includes('已有暂停须单独处理')));
  assert.ok(document.body.find('p').some(n=>n.textContent?.includes('处理不会改变资金启停')));
  const process=document.body.find('form').find(n=>n.name==='incident-process');
  assert.equal(process.find('input').find(n=>n.name==='accept_incident')['aria-label'],'我确认处理这起事故；处理不会改变资金启停');
});

test('processing a T2 source record leaves a running wallet running and gives no resume instruction',async()=>{
  let item={id:'temporary-source',code:'MANUAL_SOURCE_UNAVAILABLE',fingerprint:'manual-reserve:MANUAL_SOURCE_UNAVAILABLE',subject_id:'global',severity:'T2',status:'OPEN',version:1,condition_active:true};
  const actions=[];
  const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:true,version:1}),
    getWalletIncidents:async()=>({items:[item]}),getWalletIncident:async()=>item,
    getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'RUNNING',restriction_scopes:[],unresolved_incidents:0}),
    manualWalletIncidentAction:async(id,kind)=>{actions.push(kind);item={...item,status:kind==='resolve'?'RESOLVED':'ACKNOWLEDGED',version:item.version+1,...(kind==='review'?{condition_active:false,clearance_digest:digest}:{})};return item;},
    manualWalletControlAction:async()=>assert.fail('incident handling cannot change fund control')});
  await settle();await panel.find('button').find(n=>n.textContent==='查看事故').handlers.click();
  const form=document.body.find('form').find(n=>n.name==='incident-process');
  form.find('input').find(n=>n.name==='accept_incident').checked=true;
  form.find('input').find(n=>n.name==='operation_password').value='synthetic-password';
  await form.handlers.submit({preventDefault(){}});
  assert.deepEqual(actions,['ack','review','resolve']);
  assert.ok(panel.find('p').some(n=>n.textContent?.includes('资金已启用')));
  const message=document.body.find('p').map(n=>n.textContent??'').join(' ');
  assert.match(message,/事故已结案.*不会改变资金启停/);
  assert.doesNotMatch(message,/前往“资金启停”.*恢复资金|处理后资金仍暂停/);
});

test('restore requires separate explicit confirmation and has no technical reason input',async()=>{
 let calls=0;const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async()=>{calls++;throw {code:'NETWORK_ERROR'};}});
 await settle();const form=panel.find('form').find(x=>x.name==='control-resume');
 assert.deepEqual(form.find('input').map(x=>x.name),['confirm_restore','mfa_proof']);
 form.find('input')[1].value='123456';await form.handlers.submit({preventDefault(){}});assert.equal(calls,0);
 form.find('input')[0].checked=true;form.find('input')[1].value='654321';await form.handlers.submit({preventDefault(){}});assert.equal(calls,1);
 assert.doesNotMatch(form.find('p').map(x=>x.textContent).join(' '),/禁止重复付款/);
});
test('expired full-check history is distinguished from healthy current source diagnostics',async()=>{
 const panel=setup({getWalletMonitorStatus:async()=>({stale:true,last_success_at:'2026-09-07T01:00:00Z'}),getManualWalletDiagnostics:async()=>({source_status:'HEALTHY',coverage_status:'CURRENT'})});
 await settle();const message=panel.find('p').map(x=>x.textContent).join(' ');
 assert.match(message,/上次完整资金核验/);assert.match(message,/需重新核验/);assert.match(message,/链上数据正常/);
 assert.doesNotMatch(message,/监控证据已过期，请等待刷新/);
});

test('invalid operation password length is explained locally without a request or pending journal',async()=>{
 for(const value of ['too-short','x'.repeat(129),'😀'.repeat(11)]){
  let calls=0;const store=storage();
  const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:false,version:0}),setWalletOperationPassword:async()=>{calls++;}}, {storage:store});
  await settle();const form=panel.find('form').find(n=>n.name==='operation-password');
  for(const input of form.find('input'))input.value=input.name==='login_password'?'synthetic-login':value;
  await form.handlers.submit({preventDefault(){}});
  assert.equal(calls,0);assert.equal(store.data.size,0);
  assert.ok(form.find('p').some(n=>n.textContent?.includes('12–128')));
  assert.ok(form.find('input').every(n=>n.value===''));
 }
});

test('unknown password setup network result asks to refresh and preserves retry key',async()=>{
 const calls=[],store=storage();
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:false,version:0}),setWalletOperationPassword:async(body,options)=>{calls.push(options);throw {code:'NETWORK_ERROR'};}},{storage:store});
 await settle();const form=panel.find('form').find(n=>n.name==='operation-password');
 for(let i=0;i<2;i++){
  for(const input of form.find('input'))input.value=input.name==='login_password'?'synthetic-login':'synthetic-operation';
  await form.handlers.submit({preventDefault(){}});
 }
 assert.equal(calls.length,2);assert.equal(calls[0].idempotencyKey,calls[1].idempotencyKey);
 const message=form.find('p').map(n=>n.textContent??'').join(' ');
 assert.match(message,/网络/);assert.match(message,/刷新安全设置/);assert.doesNotMatch(message,/已设置|Failed to fetch/);
 assert.ok(!JSON.stringify([...store.data]).includes('synthetic-operation'));
});

test('fixed operation password setup preserves exact secrets and does not store them',async()=>{
 const calls=[], store=storage();let configured=false;
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured,version:configured?1:0}),
   setWalletOperationPassword:async(body,options)=>{calls.push({body,options});configured=true;return {auth_mode:'operation_password',configured:true,version:1};}}, {storage:store});
 await settle();
 assert.ok(!panel.find('form').some(n=>n.name.startsWith('mfa-')));
 const form=panel.find('form').find(n=>n.name==='operation-password');assert.ok(form);
 for(const input of form.find('input')) input.value=input.name==='login_password'?'Login-Test-Password':'  Operation-Test-2026  ';
 await form.handlers.submit({preventDefault(){}});
 assert.equal(calls[0].body.new_operation_password,'  Operation-Test-2026  ');
 assert.ok(!JSON.stringify([...store.data]).includes('Operation-Test'));
 assert.ok(form.find('input').every(n=>n.value===''));
 assert.ok(panel.find('h3').some(n=>n.textContent==='USDT 钱包'));
});

test('fixed password claim uses explicit field and stable key without storing credential',async()=>{
 const calls=[],store=storage();
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:true,version:2}),claimManualPayout:async(id,body,options)=>{calls.push({body,options});throw Error('lost');}}, {storage:store});await settle();
 await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 const form=panel.find('form').find(n=>n.name==='claim');
 for(let i=0;i<2;i++){form.find('input')[0].value='  Operation-Test-2026  ';await form.handlers.submit({preventDefault(){}});}
 assert.equal(calls[0].body.operation_password,'  Operation-Test-2026  ');assert.ok(!('mfa_proof' in calls[0].body));
 assert.equal(calls[0].options.idempotencyKey,calls[1].options.idempotencyKey);assert.ok(!JSON.stringify([...store.data]).includes('Operation-Test'));
});

test('missing or failed operation-password configuration keeps financial forms disabled',async()=>{
 for(const getWalletOperationSecurity of [async()=>({auth_mode:'operation_password',configured:false,version:0}),async()=>{throw Error('offline');}]){
   const panel=setup({getWalletOperationSecurity});await settle();
   await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
   const form=panel.find('form').find(n=>n.name==='claim');assert.equal(form.find('button')[0].disabled,true);
 }
});

test('MFA recent login rejection explains reauthentication without payment warning',async()=>{
 const panel=setup({getWalletMfaStatus:async()=>({configured:true,enabled:false,pending_credential_id:'pending'}),
   enableWalletMfa:async()=>{throw {code:'RECENT_LOGIN_REQUIRED',status:403};}}, {onReauthenticate(){}});
 await settle();
 const form=panel.find('form').find(n=>n.name==='mfa-enable');
 form.find('input')[0].value='123456';
 await form.handlers.submit({preventDefault(){}});
 const message=form.find('p').map(n=>n.textContent??'').join(' ');
 assert.match(message,/重新登录/);
 assert.match(message,/MFA/);
 assert.doesNotMatch(message,/付款|原参数/);
 assert.ok(panel.find('button').some(n=>n.textContent==='重新登录'));
 assert.equal(form.find('input')[0].value,'');
});
const storage=()=>{const data=new Map();return {data,getItem:k=>data.get(k)??null,setItem:(k,v)=>data.set(k,v),removeItem:k=>data.delete(k)};};
const digest='a'.repeat(64);
const order={id:'order',status:'REQUESTED',amount:'100000000000000001.000001',digest,snapshot:{amount:'100000000000000001.000001',fee:'0.000000',hold:'100000000000000001.000001',receive:'100000000000000001.000001',target_address:'fixture-target',official_address:'fixture-source',network:'TRON',contract:'fixture-contract',owner_admin_id:'owner'},candidates:[]};
function setup(extra={},options={}) {
  globalThis.document={body:new Element('body'),createElement:tag=>new Element(tag)};
  const api={getManualPayouts:async()=>({items:[order]}),getManualPayout:async()=>order,getWalletMfaStatus:async()=>({configured:true,enabled:true}),getWalletIncidents:async()=>({items:[]}),getWalletMonitorStatus:async()=>({stale:false,external_delivery_configured:true}),...extra};
  return manualWalletPanel(api,{actor:{id:'owner'},storage:storage(),...options});
}

test('controlled resume retains original epoch digest and key after unknown result',async()=>{
 const calls=[], store=storage();
 const extra={getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:['manual_tron'],unresolved_incidents:0}),manualWalletControlAction:async(kind,body,options)=>{calls.push({kind,body,options});throw Error('lost');}};
 for(const code of ['123456','654321']) {
   const panel=setup(extra,{storage:store});await settle();
   const form=panel.find('form').find(n=>n.name==='control-resume');assert.ok(form);
   form.find('input').find(n=>n.name==='confirm_restore').checked=true;
   form.find('input').find(n=>n.name==='mfa_proof').value=code;
   await form.handlers.submit({preventDefault(){}});
 }
 assert.equal(calls.length,2);assert.equal(calls[0].body.expected_epoch,3);
 assert.equal(calls[0].body.snapshot_digest,digest);
 assert.equal(calls[0].options.idempotencyKey,calls[1].options.idempotencyKey);
 assert.ok(!JSON.stringify([...store.data]).includes('123456'));
});

test('unresolved incidents show a disabled resume entry and recovery instructions',async()=>{
 const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:['manual_tron'],unresolved_incidents:1})});await settle();
 assert.equal(panel.find('form').some(n=>n.name==='control-resume'),false);
 assert.equal(panel.find('form').some(n=>n.name==='control-pause'),false);
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('未结事故')));
 const resume=panel.find('button').find(n=>n.textContent==='核验并恢复资金');
 assert.ok(resume);assert.equal(resume.disabled,true);
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('检查并处理事故')));
});

test('resume evidence feedback preserves the request and distinguishes it from a payment',async()=>{
 const calls=[];
 const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async(kind,body,options)=>{
   calls.push(options.idempotencyKey);throw {code:'MANUAL_CONTROL_EVIDENCE_UNAVAILABLE',fields:[{type:'wallet.control.evidence',msg:'MANUAL_COVERAGE_PENDING'}]};
 }});await settle();
 const form=panel.find('form').find(n=>n.name==='control-resume');
 for(let i=0;i<2;i++) {
   form.find('input').find(n=>n.name==='confirm_restore').checked=true;
   form.find('input').find(n=>n.name==='mfa_proof').value='123456';
   await form.handlers.submit({preventDefault(){}});
 }
 const message=form.find('p').map(n=>n.textContent??'').join(' ');
 assert.match(message,/业务流水扫描尚未追平/);assert.match(message,/本次资金恢复未提交/);
 assert.doesNotMatch(message,/禁止重复付款/);assert.equal(calls[0],calls[1]);
});

test('definitively changed control snapshot refreshes without automatic resubmission',async()=>{
 let snapshot=digest; const calls=[];
 const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:snapshot,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),manualWalletControlAction:async(kind,body,options)=>{
   calls.push({body,options});snapshot='b'.repeat(64);throw {code:'MANUAL_CONTROL_SNAPSHOT_CONFLICT'};
 }});await settle();
 async function submit() {
   const form=panel.find('form').find(n=>n.name==='control-resume');
   form.find('input').find(n=>n.name==='confirm_restore').checked=true;
   form.find('input').find(n=>n.name==='mfa_proof').value='123456';
   await form.handlers.submit({preventDefault(){}});
 }
 await submit();assert.equal(calls.length,1);
 await submit();assert.equal(calls[1].body.snapshot_digest,snapshot);
 assert.notEqual(calls[0].options.idempotencyKey,calls[1].options.idempotencyKey);
});

test('handover restores preparation and requires received notice before confirmation',async()=>{
 const store=storage();operationJournal(store,'owner').begin('handover:active',{preparation_id:'prepared'});
 const calls=[];const panel=setup({getWalletHandover:async()=>({id:'prepared',manifest_digest:digest,expires_at:'2099-01-01T00:00:00Z',status:'NOTICE_DELIVERED',incident_count:3,alert_count:295,withdrawals_paused:true}),walletHandoverAction:async(...args)=>{calls.push(args);return {status:'HANDOVER_COMPLETE_FUNDS_PAUSED'};}},{storage:store});await settle();
 const form=panel.find('form').find(n=>n.name==='handover-confirm');assert.ok(form);
 form.find('input').find(n=>n.name==='reason_code').value='LEGACY_HANDOVER_CONFIRMED';
 form.find('input').find(n=>n.name==='mfa_proof').value='123456';
 await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,0);
 for(const input of form.find('input')) if(input.type==='checkbox') input.checked=true;
 form.find('input').find(n=>n.name==='mfa_proof').value='654321';
 await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,1);
 assert.equal(calls[0][2].manifest_digest,digest);assert.equal(calls[0][2].notice_received,true);
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('交接完成，资金仍暂停')));
});

test('server invalidated handover can be explicitly regenerated despite future client expiry',async()=>{
 const store=storage();operationJournal(store,'owner').begin('handover:active',{preparation_id:'old'});
 const panel=setup({getWalletHandover:async()=>({id:'old',manifest_digest:digest,expires_at:'2099-01-01T00:00:00Z',status:'INVALID',incident_count:3,alert_count:295,withdrawals_paused:true})},{storage:store});await settle();
 const restart=panel.find('button').find(n=>n.textContent==='重新生成交接清单');assert.ok(restart);
 restart.handlers.click();await settle();
 assert.ok(panel.find('form').some(n=>n.name==='handover-prepare'));
});

test('handover evidence rejection explains coverage lag without unrelated payment warning',async()=>{
 const store=storage();operationJournal(store,'owner').begin('handover:active',{preparation_id:'prepared'});
 const panel=setup({getWalletHandover:async()=>({id:'prepared',manifest_digest:digest,expires_at:'2099-01-01T00:00:00Z',status:'NOTICE_DELIVERED',incident_count:3,alert_count:295,withdrawals_paused:true}),walletHandoverAction:async()=>{throw Object.assign(new Error('hidden-provider-detail'),{code:'HANDOVER_EVIDENCE_UNAVAILABLE',fields:[{loc:['evidence'],msg:'MANUAL_COVERAGE_PENDING',type:'wallet.handover.evidence'}]});}},{storage:store});await settle();
 const form=panel.find('form').find(n=>n.name==='handover-confirm');
 form.find('input').find(n=>n.name==='reason_code').value='OWNER_HANDOVER';
 for(const input of form.find('input')) if(input.type==='checkbox') input.checked=true;
 form.find('input').find(n=>n.name==='mfa_proof').value='123456';
 await form.handlers.submit({preventDefault(){}});
 const message=form.find('p').map(n=>n.textContent??'').join(' ');
 assert.match(message,/业务流水扫描尚未追平/);
 assert.match(message,/本次交接未提交/);
 assert.doesNotMatch(message,/禁止重复付款|hidden-provider-detail/);
});
test('exact money rejects floats and preserves six decimals',()=>{
 assert.equal(exactUsdt(order.amount),order.amount);
 for(const v of [10,'10','1e6','10.0000001']) assert.throws(()=>exactUsdt(v));
});
test('operation journal persists stable user scoped keys and rejects secret metadata',()=>{
 const store=storage(), j=operationJournal(store,'owner');
 const a=j.begin('order:claim',{expected_digest:digest});
 assert.equal(operationJournal(store,'owner').begin('order:claim',{expected_digest:digest}).key,a.key);
 assert.notEqual(operationJournal(store,'other').begin('order:claim',{expected_digest:digest}).key,a.key);
 assert.throws(()=>j.begin('secret',{mfa_proof:'123456'}));
 assert.throws(()=>j.begin('order:claim',{expected_digest:'b'.repeat(64)}));
});
test('claim displays immutable snapshot, uses MFA and same key after response loss, never marks settled',async()=>{
 const calls=[];
 const panel=setup({claimManualPayout:async(id,body,options)=>{calls.push({id,body,options});throw new Error('lost');}});
 await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 assert.ok(panel.find('dd').some(n=>n.textContent===order.amount));
 assert.equal(panel.find('button').some(n=>n.textContent==='复制收款地址'),false);
 const otp=panel.find('input').find(n=>n.name==='mfa_proof'); otp.value='123456';
 const form=panel.find('form').find(n=>n.name==='claim');
 await form.handlers.submit({preventDefault(){}}); otp.value='654321'; await form.handlers.submit({preventDefault(){}});
 assert.equal(calls[0].options.idempotencyKey,calls[1].options.idempotencyKey);
 assert.equal(calls[0].body.expected_digest,digest); assert.equal(otp.value,'');
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('结果未知')));
});
test('claimed order recovers payment details without permitting repayment and txid remains evidence',async()=>{
 const panel=setup({getManualPayout:async()=>({...order,status:'UNKNOWN',claimed_by:'owner'})});
 await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('禁止重复付款')));
 assert.ok(panel.find('button').some(n=>n.textContent==='复制收款地址'));
 assert.equal(panel.find('button').some(n=>n.textContent==='领取付款指令'),false);
 assert.ok(panel.find('form').some(n=>n.name==='txid'));
});
test('missing server key permits only password-confirmed pending cancellation',async()=>{
 const panel=setup({getWalletMfaStatus:async()=>({configured:false,enabled:false,pending_credential_id:'pending'})});
 await settle();
 assert.ok(panel.find('form').some(n=>n.name==='mfa-abort'));
 assert.ok(!panel.find('form').some(n=>['mfa-enable','mfa-enroll'].includes(n.name)));
 const enabled=setup({getWalletMfaStatus:async()=>({configured:false,enabled:true,pending_credential_id:null})});
 await settle();
 assert.ok(!enabled.find('form').some(n=>n.name==='mfa-abort'));
});

test('pending MFA enrollment is recoverable without storing provisioning secrets',async()=>{
 const panel=setup({getWalletMfaStatus:async()=>({configured:true,enabled:false,pending_credential_id:'pending'})});
 await settle();
 assert.ok(panel.find('form').some(n=>n.name==='mfa-enable'));
 assert.ok(panel.find('form').some(n=>n.name==='mfa-abort'));
});
test('loading failure is distinct from empty state',async()=>{
 const panel=setup({getManualPayouts:async()=>{throw new Error('unavailable');}}); await settle();
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('出款加载失败')));
});
test('recent login failures expose explicit login, clear secrets and preserve same-account recovery without automatic replay',async()=>{
 const store=storage(),calls=[];let logins=0;
 const api={claimManualPayout:async(id,body,options)=>{calls.push(options);throw Object.assign(new Error('recent login'),{code:'RECENT_LOGIN_REQUIRED',status:403});}};
 let panel=setup(api,{storage:store,onReauthenticate:()=>{logins++;}});await settle();await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 panel.find('input').find(n=>n.name==='mfa_proof').value='123456';
 await panel.find('form').find(n=>n.name==='claim').handlers.submit({preventDefault(){}});
 assert.equal(logins,0);const login=panel.find('button').find(n=>n.textContent==='重新登录');assert.ok(login);
 panel.find('input').find(n=>n.name==='mfa_proof').value='654321'; await login.handlers.click();
 assert.equal(logins,1);assert.equal(panel.find('input').length,0);assert.equal(calls.length,1);
 panel=setup(api,{storage:store});await settle();await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 panel.find('input').find(n=>n.name==='mfa_proof').value='111111';await panel.find('form').find(n=>n.name==='claim').handlers.submit({preventDefault(){}});
 assert.equal(calls[0].idempotencyKey,calls[1].idempotencyKey);
});
test('401 and auth errors on reads offer login but permission errors do not',async()=>{
 for(const error of [{status:401},{code:'AUTH_REQUIRED'},{code:'UNAUTHORIZED'},{code:'FORBIDDEN',status:403}]) {
 const panel=setup({getManualPayouts:async()=>{throw error;}},{onReauthenticate:()=>{}});await settle();
 assert.equal(panel.find('button').some(n=>n.textContent==='重新登录'),error.code!=='FORBIDDEN');
 }
});
test('unknown txid submission restores original safe fields after panel reload',async()=>{
 const store=storage(), calls=[], txid='b'.repeat(64);
 const api={getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'}),submitManualPayoutTxid:async(id,body,opts)=>{calls.push(opts);throw new Error('lost');}};
 let panel=setup(api,{storage:store}); await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 panel.find('input').find(n=>n.name==='txid').value=txid;
 await panel.find('form').find(n=>n.name==='txid').handlers.submit({preventDefault(){}});
 panel=setup(api,{storage:store}); await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 assert.equal(panel.find('input').find(n=>n.name==='txid').value,txid);
 await panel.find('form').find(n=>n.name==='txid').handlers.submit({preventDefault(){}});
 assert.equal(calls[0].idempotencyKey,calls[1].idempotencyKey);
});
test('copy and submission preserve exact six decimal amount, other administrator cannot claim',async()=>{
 const copies=[];
 let panel=setup({getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'})},{clipboard:{writeText:async v=>copies.push(v)}});
 await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 await panel.find('button').find(n=>n.textContent==='复制精确金额').handlers.click();
 assert.deepEqual(copies,[order.amount]);
 panel=setup({},{actor:{id:'other'}}); await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 assert.equal(panel.find('form').some(n=>n.name==='claim'),false);
});
test('owner cannot obtain payment instructions for an order claimed by another identity',async()=>{
 const panel=setup({getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'other'})});
 await settle(); await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 assert.equal(panel.find('button').some(n=>n.textContent==='复制收款地址'),false);
 assert.equal(panel.find('form').some(n=>n.name==='txid'),false);
});
test('MFA provisioning never persists secrets and removes them on completion',async()=>{
 const store=storage(); let enabled=false, received;
 const panel=setup({getWalletMfaStatus:async()=>({configured:true,enabled}),enrollWalletMfa:async body=>{received=body;return {credential_id:'pending',secret:'fixture-secret',provisioning_uri:'otpauth://fixture'};},enableWalletMfa:async()=>{enabled=true;return {enabled:true};}},{storage:store});
 await settle(); panel.find('input').find(n=>n.name==='password').value=' password ';
 await panel.find('form').find(n=>n.name==='mfa-enroll').handlers.submit({preventDefault(){}});
 assert.equal(received.password,' password ');
 assert.ok(panel.find('dd').some(n=>n.textContent==='fixture-secret'));
 assert.ok(!JSON.stringify([...store.data]).includes('fixture-secret'));
 panel.find('input').find(n=>n.name==='code').value='123456';
 await panel.find('form').find(n=>n.name==='mfa-enable').handlers.submit({preventDefault(){}});
 assert.ok(!panel.find('dd').some(n=>n.textContent==='fixture-secret'));
 assert.ok(!JSON.stringify([...store.data]).includes('123456'));
});
test('incident review uses current version and returned clearance and preserves pause after resolution',async()=>{
 const calls=[]; let incident={id:'incident',code:'MANUAL_RESERVE_STALE',severity:'P0',status:'ACKNOWLEDGED',version:2,condition_active:true};
 const panel=setup({getWalletIncidents:async()=>({items:[incident]}),getWalletIncident:async()=>incident,manualWalletIncidentAction:async(id,kind,body,options)=>{
  calls.push({id,kind,body,options}); incident={...incident,version:incident.version+1,condition_active:false,clearance_digest:digest,status:kind==='resolve'?'RESOLVED':'ACKNOWLEDGED'}; return incident;
 }}); await settle(); await panel.find('button').find(n=>n.textContent==='查看事故').handlers.click();
 assert.equal(panel.find('form').some(n=>n.name==='incident-resolve'),false);
 const submit=async code=>{const form=document.body.find('form').find(n=>n.name==='incident-process');form.find('input').find(n=>n.name==='accept_incident').checked=true;form.find('input').find(n=>n.name==='mfa_proof').value=code;await form.handlers.submit({preventDefault(){}});};
 await submit('123456'); await submit('654321');
 assert.equal(calls[0].body.expected_version,2); assert.equal(calls[1].body.expected_version,3);
 assert.equal(calls[1].body.clearance_digest,digest);
 assert.ok(document.body.find('p').some(n=>n.textContent?.includes('下一步：前往“资金启停”')));
 assert.equal(panel.find('form').some(n=>n.name==='incident-resolve'),false);
});

test('funding actions follow known authoritative status only',async()=>{
 for(const [status,expected] of [['PAUSED',['control-resume']],['ACTIVE',['control-pause']],['RUNNING',['control-pause']],['UNAVAILABLE',[]],['MYSTERY',[]]]){
  const panel=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status,restriction_scopes:[],unresolved_incidents:0})});await settle();
  assert.deepEqual(panel.find('form').filter(n=>n.name.startsWith('control-')).map(n=>n.name),expected);
 }
});

test('unified refresh preserves setup form, selected payout drafts and stale data without writes',async()=>{
 let reads=0,fail=false;const cursors=[];
 const panel=setup({getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:false,version:0}),
  getManualPayouts:async({cursor})=>{cursors.push(cursor);reads++;if(fail)throw Error('offline');return {items:[{...order,status:'CLAIMED'}],next_cursor:'page-two'};},
  getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'}),
  getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0})},{unifiedRefresh:true});
 await settle();assert.equal(typeof panel.refresh,'function');
 assert.equal(panel.find('button').filter(n=>/^刷新/.test(n.textContent??'')).length,0);
 await panel.find('button').find(n=>n.textContent==='下一页出款').handlers.click();
 await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 const security=panel.find('form').find(n=>n.name==='operation-password');security.find('input')[0].value='memory-only';
 panel.find('input').find(n=>n.name==='txid').value='b'.repeat(64);
 await panel.refresh();
 assert.equal(panel.find('form').find(n=>n.name==='operation-password'),security);
 assert.equal(security.find('input')[0].value,'memory-only');
 assert.equal(panel.find('input').find(n=>n.name==='txid').value,'b'.repeat(64));
 assert.equal(cursors.at(-1),'page-two');assert.equal(reads,3);
 fail=true;await panel.refresh();
 assert.ok(panel.find('button').some(n=>n.textContent==='查看出款'));
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('过期')));
});

test('refresh and financial submits are mutually exclusive and partial control failure disables stale actions',async()=>{
 let release,delay=false,writes=0;
 const panel=setup({getManualWalletControl:async()=>{if(delay)await new Promise(r=>release=r);if(delay)throw Error('offline');return {epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0};},manualWalletControlAction:async()=>{writes++;}},{unifiedRefresh:true});await settle();
 const form=panel.find('form').find(n=>n.name==='control-resume');for(const input of form.find('input'))input.value=input.name==='reason_code'?'CONTROL_REVIEW':'123456';
 delay=true;const pending=panel.refresh();await settle();assert.equal(await panel.refresh(),false);
 await form.handlers.submit({preventDefault(){}});assert.equal(writes,0);release();await pending;
 assert.equal(form.find('button')[0].disabled,true);assert.ok(panel.find('p').some(n=>n.textContent?.includes('过期')));
});

test('successful asynchronous recent authentication keeps nonsecret draft and never replays write',async()=>{
 let writes=0;
 const panel=setup({getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'}),submitManualPayoutTxid:async()=>{writes++;throw {code:'RECENT_LOGIN_REQUIRED'};}},{onReauthenticate:async()=>true,unifiedRefresh:true});await settle();
 await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 panel.find('input').find(n=>n.name==='txid').value='c'.repeat(64);
 await panel.find('form').find(n=>n.name==='txid').handlers.submit({preventDefault(){}});
 await panel.find('button').find(n=>n.textContent==='重新登录').handlers.click();
 assert.equal(writes,1);assert.equal(panel.find('input').find(n=>n.name==='txid').value,'c'.repeat(64));
});

test('security failure recovery re-enables unchanged setup form and clears stale notice',async()=>{
 let fail=false;const panel=setup({getWalletOperationSecurity:async()=>{if(fail)throw Error('offline');return {auth_mode:'operation_password',configured:false,version:0};}},{unifiedRefresh:true});await settle();
 fail=true;await panel.refresh();fail=false;await panel.refresh();
 assert.equal(panel.find('form').find(n=>n.name==='operation-password').find('button')[0].disabled,false);
 assert.ok(!panel.find('p').some(n=>n.textContent?.includes('安全设置暂不可用')));
});

test('refresh keeps latest typed draft and operation result while preventing writes during a detail read',async()=>{
 let release,delay=false,writes=0;
 const panel=setup({getManualPayout:async()=>{if(delay)await new Promise(r=>release=r);return {...order,status:'CLAIMED',claimed_by:'owner'};},submitManualPayoutTxid:async()=>{writes++;throw {code:'NETWORK_ERROR'};}},{unifiedRefresh:true});await settle();
 await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
 let form=panel.find('form').find(n=>n.name==='txid');form.find('input')[0].value='d'.repeat(64);await form.handlers.submit({preventDefault(){}});
 const message=form.find('p')[0].textContent;
 delay=true;const pending=panel.refresh();await settle();form.find('input')[0].value='e'.repeat(64);release();await pending;
 form=panel.find('form').find(n=>n.name==='txid');assert.equal(form.find('input')[0].value,'e'.repeat(64));assert.equal(form.find('p')[0].textContent,message);assert.equal(writes,1);
 const reading=panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();await settle();await form.handlers.submit({preventDefault(){}});assert.equal(writes,1);release();await reading;
});

test('disposing a wallet clears secrets and ignores late authentication failures',async()=>{
 let release;let logins=0;const panel=setup({getManualPayout:async()=>new Promise((resolve,reject)=>release=()=>reject({code:'RECENT_LOGIN_REQUIRED'}))},{onReauthenticate:async()=>{logins++;},unifiedRefresh:true});await settle();
 const reading=panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();await settle();
 assert.equal(typeof panel.dispose,'function');panel.dispose();release();await reading;
 assert.equal(logins,0);assert.equal(panel.find('button').some(n=>n.textContent==='重新登录'),false);assert.equal(await panel.refresh(),false);
});

test('refresh returns false for every failed panel or selected detail and true after recovery',async()=>{
 const good={getWalletOperationSecurity:async()=>({auth_mode:'totp',configured:true,version:1}),getWalletMfaStatus:async()=>({configured:true,enabled:true}),getManualPayouts:async()=>({items:[order]}),getManualPayout:async()=>order,getWalletIncidents:async()=>({items:[{id:'incident',status:'OPEN'}]}),getWalletMonitorStatus:async()=>({stale:false}),getWalletIncident:async()=>({id:'incident',status:'RESOLVED'}),getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0})};
 for(const failed of [...Object.keys(good),'all']){
  let failing=false;const api=Object.fromEntries(Object.entries(good).map(([name,run])=>[name,async(...args)=>{if(failing&&(failed==='all'||failed===name))throw Error('offline');return run(...args);} ]));
  const panel=setup(api,{unifiedRefresh:true});await settle();
  await panel.find('button').find(n=>n.textContent==='查看出款').handlers.click();
  await panel.find('button').find(n=>n.textContent==='查看事故').handlers.click();
  failing=true;assert.equal(await panel.refresh(),false,failed);
  assert.ok([...panel.find('p'),...document.body.find('p')].some(n=>n.textContent?.includes('过期')),failed);
  failing=false;assert.equal(await panel.refresh(),true,failed);
 }
});


const ownerTxid='a'.repeat(64);
const ownerOtherTxid='b'.repeat(64);
const ownerPreview=(overrides={})=>({
 txid:ownerTxid,log_index:7,to_address:'fixture-recipient',
 amount_units:'100000000000000001000001',reason_code:'OWNER_TEST_DRAW',
 reason_detail:'官方钱包持有人测试转出',declared_by:'owner',blockers:[],...overrides
});
const ownerPurpose=form=>form.find('select').find(input=>input.name==='purpose');
const ownerDraft=form=>{
 form.find('input').find(input=>input.name==='txid').value=ownerTxid;
 ownerPurpose(form).value='test';
 form.find('input').find(input=>input.name==='ownership_attested').checked=true;
};
const openOwnerDialogs=()=>document.body.find('dialog').filter(dialog=>dialog.open&&!dialog.removed);
const ownerConfirm=()=>openOwnerDialogs().flatMap(dialog=>dialog.find('button')).find(button=>button.textContent==='确认申报');

test('owner transfer requires empty-default purpose and previews a unique nonzero event without executing',async()=>{
 const previews=[],executions=[];
 const panel=setup({previewOwnerTransfer:async body=>{previews.push(body);return ownerPreview();},
  executeOwnerTransfer:async(...args)=>{executions.push(args);return ownerPreview();}},{walletAccess:true});
 await settle();const form=panel.find('form').find(item=>item.name==='owner-transfer');
 assert.ok(form);assert.deepEqual(form.find('input').map(input=>input.name),['txid','ownership_attested']);
 const purpose=ownerPurpose(form);assert.ok(purpose);assert.equal(purpose.value,'');
 assert.deepEqual(purpose.find('option').map(option=>[option.value,option.textContent]),
  [['','请选择转出用途'],['test','钱包测试转出'],['payment','对外付款']]);
 form.find('input').find(input=>input.name==='txid').value=ownerTxid;
 form.find('input').find(input=>input.name==='ownership_attested').checked=true;
 await form.handlers.submit({preventDefault(){}});
 assert.equal(previews.length,0);
 assert.ok(form.find('p').some(item=>item.textContent?.includes('请选择转出用途')));
 purpose.value='test';await form.handlers.submit({preventDefault(){}});
 assert.deepEqual(previews,[{txid:ownerTxid,reason_code:'OWNER_TEST_DRAW',
  reason_detail:'官方钱包持有人测试转出',ownership_attested:true}]);
 assert.equal(executions.length,0);
 const dialog=openOwnerDialogs()[0];assert.ok(dialog);
 const details=dialog.find('dd').map(item=>item.textContent);
 assert.ok(details.includes('100000000000000001.000001 USDT'));
 assert.ok(details.includes('fixture-recipient'));
 assert.ok(details.includes('钱包测试转出'));
 assert.ok(details.some(value=>value.includes(ownerTxid.slice(0,8))&&value.includes(ownerTxid.slice(-6))));
 assert.ok(ownerConfirm());
});

test('external payment purpose is fixed and controlled chain candidate supplies exact preview index',async()=>{
 const previews=[];
 const panel=setup({previewOwnerTransfer:async body=>{previews.push(body);return ownerPreview({reason_code:'OWNER_EXTERNAL_PAYMENT',reason_detail:'官方钱包持有人对外付款'});}},{walletAccess:true});
 await settle();
 assert.equal(typeof panel.selectOwnerTransferCandidate,'function');
 assert.equal(panel.selectOwnerTransferCandidate({txid:ownerTxid,log_index:-1,amount:'1.000000',to_address:'fixture-recipient',timestamp_ms:1}),false);
 assert.equal(panel.selectOwnerTransferCandidate({txid:ownerTxid,log_index:7,amount:'1e3',to_address:'fixture-recipient',timestamp_ms:1}),false);
 assert.equal(panel.selectOwnerTransferCandidate({txid:ownerTxid,log_index:7,amount:'100000000000000001.000001',to_address:'fixture-recipient',timestamp_ms:1780000000000}),true);
 const form=panel.find('form').find(item=>item.name==='owner-transfer');
 ownerPurpose(form).value='payment';form.find('input').find(input=>input.name==='ownership_attested').checked=true;
 await form.handlers.submit({preventDefault(){}});
 assert.deepEqual(previews,[{txid:ownerTxid,log_index:7,reason_code:'OWNER_EXTERNAL_PAYMENT',
  reason_detail:'官方钱包持有人对外付款',ownership_attested:true}]);
 assert.ok(ownerConfirm());
 ownerPurpose(form).value='test';ownerPurpose(form).handlers.change?.();
 assert.equal(ownerConfirm(),undefined);
});

test('ambiguous or absent owner outflow stops at preview with actionable guidance',async()=>{
 for(const [code,text] of [['TRANSFER_SELECTION_REQUIRED','链上流水'],['TRANSFER_NOT_FOUND','没有可申报']]){
  let writes=0;
  const panel=setup({previewOwnerTransfer:async()=>{throw {code};},executeOwnerTransfer:async()=>{writes++;}},{walletAccess:true});
  await settle();const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
  await form.handlers.submit({preventDefault(){}});
  assert.equal(writes,0);assert.equal(ownerConfirm(),undefined);
  assert.ok(form.find('p').some(item=>item.textContent?.includes(text)),code);
  panel.dispose();
 }
});

test('selected chain candidate must agree with fresh preview amount and destination',async()=>{
 for(const changed of [{amount_units:'100000000000000001000002'},{to_address:'different-recipient'}]){
  let writes=0;
  const panel=setup({previewOwnerTransfer:async()=>ownerPreview(changed),executeOwnerTransfer:async()=>{writes++;}},{walletAccess:true});
  await settle();
  assert.equal(panel.selectOwnerTransferCandidate({txid:ownerTxid,log_index:7,amount:'100000000000000001.000001',
   to_address:'fixture-recipient',timestamp_ms:1780000000000}),true);
  const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerPurpose(form).value='test';
  form.find('input').find(input=>input.name==='ownership_attested').checked=true;
  await form.handlers.submit({preventDefault(){}});
  assert.equal(ownerConfirm(),undefined);assert.equal(writes,0);
 }
});

test('owner preview rejects unbounded amount units before showing a confirmation',async()=>{
 let writes=0;
 const panel=setup({previewOwnerTransfer:async()=>ownerPreview({amount_units:'9'.repeat(1000)}),
  executeOwnerTransfer:async()=>{writes++;}},{walletAccess:true});
 await settle();const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 await form.handlers.submit({preventDefault(){}});
 assert.equal(ownerConfirm(),undefined);assert.equal(writes,0);
});

test('owner confirmation double click and another financial command share one write lock',async()=>{
 let release,executions=0,pauses=0;
 const panel=setup({previewOwnerTransfer:async()=>ownerPreview(),
  executeOwnerTransfer:async()=>{executions++;return new Promise(resolve=>release=()=>resolve({...ownerPreview(),status:'DECLARED',replayed:false}));},
  getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'ACTIVE',restriction_scopes:[],unresolved_incidents:0}),
  manualWalletControlAction:async()=>{pauses++;}},{walletAccess:true});
 await settle();const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 await form.handlers.submit({preventDefault(){}});
 const confirm=ownerConfirm();assert.ok(confirm);
 const first=confirm.handlers.click();await settle();const second=confirm.handlers.click();
 const pause=panel.find('form').find(item=>item.name==='control-pause');
 pause.find('input')[0].checked=true;await pause.handlers.submit({preventDefault(){}});
 assert.equal(executions,1);assert.equal(pauses,0);
 release();await Promise.all([first,second]);assert.equal(executions,1);
});

test('lost wallet grant closes owner confirmation and requires a new deliberate preview and click',async()=>{
 let authorized=true,prompts=0,writes=0;
 const panel=setup({previewOwnerTransfer:async()=>ownerPreview(),executeOwnerTransfer:async()=>{writes++;}},
  {walletAccess:true,accessController:{canWrite:()=>authorized,requestWriteGrant:async()=>{prompts++;authorized=true;return true;}}});
 await settle();const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 await form.handlers.submit({preventDefault(){}});
 authorized=false;await ownerConfirm().handlers.click();
 assert.equal(writes,0);assert.equal(prompts,1);assert.equal(ownerConfirm(),undefined);
 await form.handlers.submit({preventDefault(){}});assert.ok(ownerConfirm());assert.equal(writes,0);
});

test('unknown owner transfer retains one fixed journal key and only exact status closes it',async()=>{
 const store=storage(),calls=[],txid=ownerTxid;
 let status={txid,transfers:[{...ownerPreview({log_index:8}),status:'DECLARED'}]};
 const api={previewOwnerTransfer:async()=>ownerPreview(),
  executeOwnerTransfer:async(body,options)=>{calls.push({body,options});throw {code:'NETWORK_ERROR'};},
  getOwnerTransfer:async()=>status};
 let panel=setup(api,{walletAccess:true,storage:store});await settle();
 let form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 await form.handlers.submit({preventDefault(){}});await ownerConfirm().handlers.click();
 assert.equal(calls.length,1);assert.equal(calls[0].body.log_index,7);
 assert.match(calls[0].options.idempotencyKey,/^[0-9a-f-]{36}$/);
 const pending=operationJournal(store,'owner').pending('owner-transfer');
 assert.deepEqual(pending.metadata,{txid,log_index:7,reason_code:'OWNER_TEST_DRAW'});
 assert.ok(!JSON.stringify([...store.data]).includes('fixture-recipient'));
 panel.dispose();panel=setup(api,{walletAccess:true,storage:store});await settle();
 form=panel.find('form').find(item=>item.name==='owner-transfer');
 form.find('input').find(input=>input.name==='txid').value=ownerOtherTxid;
 ownerPurpose(form).value='payment';form.find('input').find(input=>input.name==='ownership_attested').checked=true;
 await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,1);
 let query=panel.find('button').find(button=>button.textContent==='查询原申报状态');assert.ok(query);
 await query.handlers.click();assert.ok(operationJournal(store,'owner').pending('owner-transfer'));
 status={txid,transfers:[{...ownerPreview({reason_detail:'不匹配说明'}),status:'DECLARED'}]};
 await query.handlers.click();assert.ok(operationJournal(store,'owner').pending('owner-transfer'));
 status={txid,transfers:[{...ownerPreview({reason_code:'OWNER_EXTERNAL_PAYMENT'}),status:'DECLARED'}]};
 await query.handlers.click();assert.ok(operationJournal(store,'owner').pending('owner-transfer'));
 status={txid,transfers:[{...ownerPreview({declared_by:'other'}),status:'DECLARED'}]};
 await query.handlers.click();assert.ok(operationJournal(store,'owner').pending('owner-transfer'));
 status={txid,transfers:[{...ownerPreview(),status:'DECLARED'}]};
 await query.handlers.click();assert.equal(operationJournal(store,'owner').pending('owner-transfer'),null);
});

test('owner pending result can retry only after lookup, with original HTTP key and exact payload',async()=>{
 const store=storage(),calls=[];
 const api={previewOwnerTransfer:async body=>ownerPreview({log_index:body.log_index??7}),
  executeOwnerTransfer:async(body,options)=>{calls.push({body,options});throw {code:'NETWORK_ERROR'};},
  getOwnerTransfer:async()=>({txid:ownerTxid,transfers:[]})};
 const panel=setup(api,{walletAccess:true,storage:store});await settle();
 const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 await form.handlers.submit({preventDefault(){}});await ownerConfirm().handlers.click();
 const key=calls[0].options.idempotencyKey;
 await form.handlers.submit({preventDefault(){}});assert.equal(calls.length,1);
 await panel.find('button').find(button=>button.textContent==='查询原申报状态').handlers.click();
 assert.ok(panel.find('p').some(item=>item.textContent?.includes('原请求')));
 form.find('input').find(input=>input.name==='ownership_attested').checked=true;
 await form.handlers.submit({preventDefault(){}});
 assert.equal(calls.length,1);assert.ok(ownerConfirm());
 await ownerConfirm().handlers.click();
 assert.equal(calls.length,2);
 assert.equal(calls[1].options.idempotencyKey,key);
 assert.deepEqual(calls[1].body,calls[0].body);
});

test('access suspension closes body dialogs, clears owner draft, and late preview cannot reopen',async()=>{
 let releasePreview;
 const panel=setup({previewOwnerTransfer:async()=>new Promise(resolve=>releasePreview=resolve),
  getWalletIncidents:async()=>({items:[{id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true}]}),
  getWalletIncident:async()=>({id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true})},{walletAccess:true});
 await settle();await panel.find('button').find(button=>button.textContent==='查看事故').handlers.click();
 assert.equal(openOwnerDialogs().length,1);
 const incidentForm=document.body.find('form').find(item=>item.name==='incident-process');
 incidentForm.find('input').find(input=>input.name==='accept_incident').checked=true;
 assert.equal(typeof panel.suspendForAccessCheck,'function');
 panel.suspendForAccessCheck();assert.equal(openOwnerDialogs().length,0);
 assert.equal(incidentForm.find('input').find(input=>input.name==='accept_incident').checked,false);
 const form=panel.find('form').find(item=>item.name==='owner-transfer');ownerDraft(form);
 const pending=form.handlers.submit({preventDefault(){}});await settle();
 panel.suspendForAccessCheck();releasePreview(ownerPreview());await pending;
 assert.equal(openOwnerDialogs().length,0);
 assert.equal(form.find('input').find(input=>input.name==='txid').value,'');
 assert.equal(ownerPurpose(form).value,'');
 assert.equal(form.find('input').find(input=>input.name==='ownership_attested').checked,false);
});

test('owner incident wording says write verification is on demand and requires a second confirmation',async()=>{
 let checks=0,writes=0;
 const incident={id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true};
 const panel=setup({getWalletIncidents:async()=>({items:[incident]}),getWalletIncident:async()=>incident,
  manualWalletIncidentAction:async()=>{writes++;}},
  {walletAccess:true,accessController:{canWrite:()=>false,requestWriteGrant:async()=>{checks++;return true;}}});
 await settle();await panel.find('button').find(button=>button.textContent==='查看事故').handlers.click();
 const explanation=document.body.find('p').map(item=>item.textContent??'').join(' ');
 assert.doesNotMatch(explanation,/钱包身份已验证/);
 assert.match(explanation,/按需验证/);
 assert.match(explanation,/重新确认/);
 const form=document.body.find('form').find(item=>item.name==='incident-process');
 form.find('input').find(input=>input.name==='accept_incident').checked=true;
 await form.handlers.submit({preventDefault(){}});
 assert.equal(checks,1);assert.equal(writes,0);
});

test('manual wallet sections expose stable payout monitor owner and security anchor ids',async()=>{
 const panel=setup({}, {walletAccess:true,unifiedRefresh:true});await settle();
 const ids=['wallet-payout','wallet-monitor','wallet-owner','wallet-security'];
 const sections=ids.map(id=>panel.find('section').find(section=>section.id===id));
 assert.ok(sections.every(Boolean));
 await panel.refresh();
 assert.deepEqual(ids.map(id=>panel.find('section').find(section=>section.id===id)),sections);
});

test('access suspension during refresh cannot restore a detached payout draft or operation password',async()=>{
 let delayControl=false,releaseControl;
 const control={epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0};
 const panel=setup({
  getWalletOperationSecurity:async()=>({auth_mode:'operation_password',configured:true,version:1}),
  getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'}),
  getManualWalletControl:async()=>delayControl?new Promise(resolve=>{releaseControl=()=>resolve(control);}):control
 },{unifiedRefresh:true});
 await settle();await panel.find('button').find(button=>button.textContent==='查看出款').handlers.click();
 const form=panel.find('form').find(item=>item.name==='txid');assert.ok(form);
 form.find('input').find(input=>input.name==='txid').value='c'.repeat(64);
 form.find('input').find(input=>input.name==='operation_password').value='synthetic-private-password';
 const readFilter=panel.find('form').find(item=>item.name==='monitoring-filters').find('select').find(input=>input['aria-label']==='事故等级');
 readFilter.value='T2';
 delayControl=true;const pending=panel.refresh();await settle();
 const replacement=panel.find('form').find(item=>item.name==='txid');assert.notEqual(replacement,form);
 panel.suspendForAccessCheck();
 assert.equal(replacement.find('input').find(input=>input.name==='txid').value,'');
 assert.equal(replacement.find('input').find(input=>input.name==='operation_password').value,'');
 releaseControl();await pending;
 const after=panel.find('form').find(item=>item.name==='txid');
 assert.equal(after,undefined);
 assert.equal(document.body.find('dialog').filter(item=>item.open).length,0);
 assert.equal(form.find('input').find(input=>input.name==='operation_password').value,'');
 assert.equal(readFilter.value,'T2');
});

test('incident detail root exposes a stable styling class',async()=>{
 const incident={id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true};
 const panel=setup({getWalletIncidents:async()=>({items:[incident]}),getWalletIncident:async()=>incident});
 await settle();await panel.find('button').find(button=>button.textContent==='查看事故').handlers.click();
 assert.ok(document.body.find('section').some(section=>section.className==='wallet-incident-detail'));
});

test('payout queue and detail identify user withdrawal origin, order number, and chain hashes',async()=>{
 const panel=setup();await settle();
 const queue=panel.find('section').find(section=>section.id==='wallet-payout');assert.ok(queue);
 assert.match(queue.find('h4')[0].textContent,/用户提现申请/);
 const row=queue.find('article')[0];
 assert.match(row.find('p').map(item=>item.textContent).join(' '),/来源：用户提现申请/);
 assert.match(row.find('p').map(item=>item.textContent).join(' '),/人工出款订单编号：order/);
 await row.find('button').find(button=>button.textContent==='查看出款').handlers.click();
 const detail=queue.find('section').find(section=>section.className==='wallet-detail');
 assert.match(detail.find('h4')[0].textContent,/用户提现申请/);
 const labels=detail.find('dt').map(item=>item.textContent);
 assert.ok(labels.includes('人工出款订单编号'));
 assert.ok(labels.includes('候选链上交易哈希'));
 assert.ok(labels.includes('结算链上交易哈希'));
});

test('monitor heartbeat and incident records have separate sections without changing filters',async()=>{
 const queries=[];
 const panel=setup({getWalletIncidents:async query=>{queries.push(query);return {items:[]};}},{unifiedRefresh:true});
 await settle();
 const monitoring=panel.find('section').find(section=>section.id==='wallet-monitor');
 const heartbeat=monitoring.find('section').find(section=>section.className==='wallet-monitor-heartbeat');
 const records=monitoring.find('section').find(section=>section.className==='wallet-monitor-incidents');
 assert.ok(heartbeat);assert.ok(records);assert.notEqual(heartbeat,records);
 assert.match(heartbeat.find('h5')[0].textContent,/监控心跳/);
 assert.match(records.find('h5')[0].textContent,/事故记录/);
 assert.ok(heartbeat.find('button').some(button=>button.textContent==='检查当前状态'));
 const filter=records.find('form').find(form=>form.name==='monitoring-filters');assert.ok(filter);
 filter.find('select').find(select=>select['aria-label']==='事故等级').value='T2';
 await filter.find('button').find(button=>button.textContent==='查询').handlers.click();
  assert.equal(queries.at(-1).severity,'T2');
});

test('payout queue shows its own Beijing read time after initial load and local refresh',async t=>{
  let instant=Date.parse('2026-09-29T00:00:00Z'),reads=0;
  t.mock.method(Date,'now',()=>instant);
  const panel=setup({getManualPayouts:async()=>{reads++;return {items:reads===1?[order]:[]};}});
  await settle();
  const queue=panel.find('section').find(section=>section.id==='wallet-payout');
  assert.ok(queue.find('p').some(item=>item.textContent==='金额均为 USDT，保留六位小数。队列读取于 2026-09-29 08:00:00。'));
  instant=Date.parse('2026-09-29T01:02:03Z');
  await queue.find('button').find(button=>button.textContent==='刷新出款队列').handlers.click();
  assert.equal(reads,2);
  assert.ok(queue.find('p').some(item=>item.textContent==='暂无人工出款。队列读取于 2026-09-29 09:02:03。'));
});

test('incident list shows its own Beijing read time and keeps stale error feedback',async t=>{
  let instant=Date.parse('2026-09-29T00:00:00Z'),reads=0;
  t.mock.method(Date,'now',()=>instant);
  const panel=setup({getWalletIncidents:async()=>{reads++;if(reads===3)throw Error('offline');return {items:[]};}});
  await settle();
  const monitoring=panel.find('section').find(section=>section.id==='wallet-monitor');
  const records=monitoring.find('section').find(section=>section.className==='wallet-monitor-incidents');
  assert.ok(records.find('p').some(item=>item.textContent==='事故列表读取于 2026-09-29 08:00:00。'));
  assert.ok(records.find('p').some(item=>item.textContent==='暂无事故记录'));
  instant=Date.parse('2026-09-29T01:02:03Z');
  const refresh=monitoring.find('button').find(button=>button.textContent==='刷新监控和事故');
  await refresh.handlers.click();
  assert.equal(reads,2);
  assert.ok(records.find('p').some(item=>item.textContent==='事故列表读取于 2026-09-29 09:02:03。'));
  await refresh.handlers.click();
  assert.ok(records.find('p').some(item=>item.textContent?.includes('事故加载失败')));
  assert.ok(records.find('p').some(item=>item.textContent==='事故列表读取于 2026-09-29 09:02:03。'));
});

test('critical wallet writes expose a dedicated button class while read actions do not',async()=>{
 const incident={id:'incident',code:'MANUAL_SOURCE_UNHEALTHY',status:'OPEN',version:1,condition_active:true};
 const panel=setup({getWalletIncidents:async()=>({items:[incident]}),getWalletIncident:async()=>incident,
  getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'ACTIVE',restriction_scopes:[],unresolved_incidents:0}),
  previewOwnerTransfer:async()=>ownerPreview()},{walletAccess:true});
 await settle();
 await panel.find('button').find(button=>button.textContent==='查看出款').handlers.click();
 const submitFor=(root,name)=>root.find('form').find(form=>form.name===name).find('button').find(button=>button.type==='submit');
 assert.match(submitFor(panel,'claim').className,/\bwallet-critical-action\b/);
 assert.match(submitFor(panel,'control-pause').className,/\bwallet-critical-action\b/);
 await panel.find('button').find(button=>button.textContent==='查看事故').handlers.click();
 const incidentSubmit=document.body.find('form').find(form=>form.name==='incident-process').find('button').find(button=>button.type==='submit');
 assert.match(incidentSubmit.className,/\bwallet-critical-action\b/);
 assert.doesNotMatch(panel.find('button').find(button=>button.textContent==='检查当前状态').className,/\bwallet-critical-action\b/);
 const owner=panel.find('form').find(form=>form.name==='owner-transfer');ownerDraft(owner);
 await owner.handlers.submit({preventDefault(){}});
 assert.match(ownerConfirm().className,/\bwallet-critical-action\b/);
 panel.dispose();
 const paused=setup({getManualWalletControl:async()=>({epoch:3,snapshot_digest:digest,status:'PAUSED',restriction_scopes:[],unresolved_incidents:0}),
  getManualPayout:async()=>({...order,status:'CLAIMED',claimed_by:'owner'})},{walletAccess:true});
 await settle();await paused.find('button').find(button=>button.textContent==='查看出款').handlers.click();
 assert.match(submitFor(paused,'control-resume').className,/\bwallet-critical-action\b/);
 assert.match(submitFor(paused,'txid').className,/\bwallet-critical-action\b/);
});
