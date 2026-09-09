import test from 'node:test';
import assert from 'node:assert/strict';
import {manualWalletPanel, operationJournal, exactUsdt} from '../src/admin-manual-wallet-panel.js';
class Element {
  constructor(tag) { this.tag=tag; this.children=[]; this.style={}; this.handlers={}; this.value=''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children=children; }
  setAttribute(name,value) { this[name]=value; }
  addEventListener(name,fn) { this.handlers[name]=fn; }
  find(tag) { return [this,...this.children.flatMap(c=>c.find(tag))].filter(c=>c.tag===tag); }
}
const settle=()=>new Promise(r=>setImmediate(r));

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
 const form=panel.find('form').find(x=>x.name==='incident-process');assert.ok(form);
 assert.equal(panel.find('form').filter(x=>x.name.startsWith('incident-')).length,1);
 assert.deepEqual(form.find('input').map(x=>x.name),['accept_incident','operation_password']);
 assert.equal(form.find('input')[0]['aria-label'],'我确认处理这起事故；完成后可前往“资金启停”恢复资金');
 assert.ok(panel.find('details').some(x=>x.find('summary').some(x=>x.textContent==='技术详情与时间线')));
 assert.ok(panel.find('dd').some(x=>x.textContent?.includes('17:08:55')));
 assert.ok(panel.find('p').some(x=>x.textContent?.includes('链上数据正常')));
 assert.ok(panel.find('p').some(x=>x.textContent?.includes('当时链上数据未满足健康要求')));
 form.find('input')[0].checked=true;form.find('input')[1].value='synthetic-password';
 await form.handlers.submit({preventDefault(){}});
 assert.deepEqual(calls,['ack','review','resolve']);assert.equal(form.find('input')[1].value,'');
 assert.ok(!JSON.stringify([...store.data]).includes('synthetic-password'));
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
  globalThis.document={createElement:tag=>new Element(tag)};
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
 const submit=async code=>{const form=panel.find('form').find(n=>n.name==='incident-process');form.find('input').find(n=>n.name==='accept_incident').checked=true;form.find('input').find(n=>n.name==='mfa_proof').value=code;await form.handlers.submit({preventDefault(){}});};
 await submit('123456'); await submit('654321');
 assert.equal(calls[0].body.expected_version,2); assert.equal(calls[1].body.expected_version,3);
 assert.equal(calls[1].body.clearance_digest,digest);
 assert.ok(panel.find('p').some(n=>n.textContent?.includes('下一步：前往“资金启停”')));
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
  assert.ok(panel.find('p').some(n=>n.textContent?.includes('过期')),failed);
  failing=false;assert.equal(await panel.refresh(),true,failed);
 }
});
