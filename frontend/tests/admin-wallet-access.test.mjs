import test from 'node:test';
import assert from 'node:assert/strict';
const module=await import('../src/admin-wallet-access.js').catch(()=>({}));
const start=Date.parse('2026-09-10T00:00:00Z');
const status=(elapsed=0)=>({enabled:true,verified:true,configured:true,auth_mode:'operation_password',verified_at:new Date(start).toISOString(),expires_at:new Date(start+3600000).toISOString(),server_time:new Date(start+elapsed).toISOString()});
function fixture(api={}){
 assert.equal(typeof module.createWalletAccess,'function','wallet access controller is implemented');
 let clock=0,actor='a',scheduled;const changes=[];
 const gate=module.createWalletAccess({api:{getWalletAccess:async()=>status(clock),...api},actorId:'a',getActorId:()=>actor,now:()=>clock,setTimer:fn=>{scheduled=fn;return 1;},clearTimer:()=>{},onChange:s=>changes.push(s)});
 return {gate,changes,tick:n=>{clock=n;scheduled?.();},actor:value=>actor=value};
}
test('cached server access remains usable after five minutes but locks at fixed sixty minutes',async()=>{
 const f=fixture();await f.gate.check();assert.equal(f.gate.allowed(),true);
 f.tick(300001);assert.equal(f.gate.allowed(),true);
 f.tick(3599999);assert.equal(f.gate.allowed(),true);
 f.tick(3600000);assert.equal(f.gate.allowed(),false);assert.equal(f.gate.state().kind,'verify');
});
test('server status after refresh reuses remaining lifetime without extending deadline',async()=>{
 const f=fixture({getWalletAccess:async()=>status(3599000)});await f.gate.check();f.tick(999);assert.equal(f.gate.allowed(),true);f.tick(1000);assert.equal(f.gate.allowed(),false);
});
test('unknown network status locks instead of showing stale balances',async()=>{
 let failed=false;const f=fixture({getWalletAccess:async()=>{if(failed)throw {code:'NETWORK_ERROR'};return status();}});
 await f.gate.check();failed=true;await f.gate.check();assert.equal(f.gate.allowed(),false);assert.equal(f.gate.state().kind,'network');
});
test('cross-account and disposed late responses cannot unlock or deliver wallet reads',async()=>{
 let release;const f=fixture({getWalletAccess:()=>new Promise(r=>release=r)});const pending=f.gate.check();f.actor('b');release(status());await pending;assert.equal(f.gate.allowed(),false);
 const g=fixture();await g.gate.check();const read=g.gate.guard(()=>new Promise(r=>release=r));g.gate.dispose();release({balance:'sensitive'});await assert.rejects(read);
});
test('authorization categories distinguish wallet expiry, global expiry and permission denial',async()=>{
 for(const [error,kind] of [[{status:403,code:'WALLET_ACCESS_REQUIRED'},'verify'],[{status:401},'login'],[{status:403,code:'PERMISSION_DENIED'},'forbidden']]){
  const f=fixture();await f.gate.check();await assert.rejects(f.gate.guard(async()=>{throw error;}));assert.equal(f.gate.state().kind,kind);
 }
});
test('credential rotation retains explicit recent-login flow without locking ordinary valid grant',async()=>{
 const f=fixture();await f.gate.check();await assert.rejects(f.gate.guard(async()=>{throw {status:403,code:'RECENT_LOGIN_REQUIRED'};},{credentialChange:true}));assert.equal(f.gate.state().kind,'ready');
});
test('invalid or replayed TOTP remains retryable wallet verification',async()=>{
 for(const code of ['TOTP_INVALID','TOTP_REPLAYED']){const f=fixture({getWalletAccess:async()=>({...status(),verified:false}),verifyWalletAccess:async()=>{throw {status:403,code};}});await f.gate.check();await f.gate.verify({mfa_proof:'123456'});assert.equal(f.gate.state().kind,'verify');}
});
test('disabled feature preserves legacy behavior; verify never automatically invokes a command',async()=>{
 const f=fixture({getWalletAccess:async()=>({enabled:false})});await f.gate.check();assert.equal(f.gate.state().kind,'legacy');assert.equal(await f.gate.guard(async()=>42),42);
 await assert.rejects(f.gate.guard(async()=>{throw {status:403,code:'RECENT_LOGIN_REQUIRED'};}));assert.equal(f.gate.state().kind,'legacy','legacy reauthentication belongs to existing panel');
 let verifies=0;const g=fixture({getWalletAccess:async()=>({...status(),verified:false}),verifyWalletAccess:async body=>{verifies++;assert.deepEqual(body,{operation_password:'secret'});return status();}});await g.gate.check();await g.gate.verify({operation_password:'secret'});assert.equal(verifies,1);assert.equal(g.gate.allowed(),true);
});

class PanelElement {
 constructor(tag) { this.tag=tag;this.children=[];this.style={};this.handlers={};this.className='';this.hidden=false;this.inert=false;this.open=false;this.textContent='';this.classList={add:()=>{},remove:()=>{}}; }
 append(...children) { this.children.push(...children); }
 replaceChildren(...children) { this.children=children; }
 setAttribute(name,value) { this[name]=value; }
 addEventListener(name,handler) { this.handlers[name]=handler; }
 remove() { this.removed=true; }
 focus() {}
 showModal() { this.open=true;this.showModalCalls=(this.showModalCalls??0)+1;globalThis.document.modalCalls++; }
 close() { this.open=false;this.handlers.close?.(); }
 find(tag) { return [this,...this.children.flatMap(child=>child?.find?.(tag)??[])].filter(child=>child.tag===tag); }
}
function installPanelDocument() {
 const body=new PanelElement('body'),app=new PanelElement('main');app.id='app';body.append(app);
 const listeners=new Map();
 const original={document:globalThis.document,addEventListener:globalThis.addEventListener,removeEventListener:globalThis.removeEventListener,BroadcastChannel:globalThis.BroadcastChannel};
 globalThis.document={body,hidden:false,modalCalls:0,createElement:tag=>new PanelElement(tag),querySelector:selector=>selector==='#app'?app:null,addEventListener:(name,handler)=>listeners.set(`document:${name}`,handler),removeEventListener:name=>listeners.delete(`document:${name}`)};
 globalThis.addEventListener=(name,handler)=>listeners.set(`global:${name}`,handler);
 globalThis.removeEventListener=name=>listeners.delete(`global:${name}`);
 globalThis.BroadcastChannel=undefined;
 return {body,app,focus:()=>listeners.get('global:focus')?.(),restore:()=>Object.assign(globalThis,original)};
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const panelStatus=(overrides={})=>({enabled:true,verified:true,configured:true,auth_mode:'operation_password',server_time:new Date(start).toISOString(),expires_at:new Date(start+3600000).toISOString(),...overrides});

test('delayed verified access and focus rechecks never create a modal or obscure the page',async()=>{
 const dom=installPanelDocument();let release,checks=0,contentCalls=0,root;
 try {
  root=module.walletAccessPanel({getWalletAccess:()=>{checks++;return new Promise(resolve=>release=resolve);}},{actor:{id:'a'},renderContent:()=>{contentCalls++;return new PanelElement('article');}});
  dom.app.append(root);await settle();
  const pending=root.find('p').find(node=>node.role==='status');assert.equal(pending?.textContent,'正在确认钱包验证状态…');assert.equal(pending?.hidden,false);
  assert.equal(dom.body.find('dialog').length,0);assert.equal(globalThis.document.modalCalls,0);assert.equal(dom.app.inert,false);assert.equal(contentCalls,0);
  release(panelStatus());await settle();await settle();
  assert.equal(pending.hidden,true);assert.equal(dom.body.find('dialog').length,0);assert.equal(globalThis.document.modalCalls,0);assert.equal(dom.app.inert,false);assert.equal(contentCalls,1);
  dom.focus();await settle();assert.equal(dom.body.find('dialog').length,0);assert.equal(dom.app.inert,false);
  release(panelStatus());await settle();await settle();
  assert.equal(dom.body.find('dialog').length,0);assert.equal(globalThis.document.modalCalls,0);assert.equal(dom.app.inert,false);assert.ok(checks>=2);
 } finally { root?.dispose();dom.restore(); }
});

test('unverified or expired responses show the existing access dialog only after server confirmation',async()=>{
 for(const response of [panelStatus({verified:false}),panelStatus({expires_at:new Date(start).toISOString()})]) {
  const dom=installPanelDocument();let root;
  try {
   root=module.walletAccessPanel({getWalletAccess:async()=>response},{actor:{id:'a'},renderContent:()=>assert.fail('locked access must not render content')});dom.app.append(root);await settle();await settle();
   const dialog=dom.body.find('dialog')[0];assert.ok(dialog?.open);assert.equal(dom.app.inert,true);
  } finally { root?.dispose();dom.restore(); }
 }
});

test('disposed pending status cannot create access UI, and a network recheck removes sensitive content',async()=>{
 const dom=installPanelDocument();let release,network=false,root,active;
 try {
  root=module.walletAccessPanel({getWalletAccess:()=>network?Promise.reject({code:'NETWORK_ERROR'}):new Promise(resolve=>release=resolve)},{actor:{id:'a'},renderContent:()=>{const content=new PanelElement('article');content.textContent='SENSITIVE-BALANCE';return content;}});dom.app.append(root);await settle();root.dispose();release(panelStatus({verified:false}));await settle();assert.equal(dom.body.find('dialog').length,0);
  active=module.walletAccessPanel({getWalletAccess:async()=>{if(network)throw {code:'NETWORK_ERROR'};return panelStatus();}},{actor:{id:'a'},renderContent:()=>{const content=new PanelElement('article');content.textContent='SENSITIVE-BALANCE';return content;}});dom.app.append(active);await settle();await settle();network=true;await active.refresh();assert.equal(active.find('article').some(node=>node.textContent==='SENSITIVE-BALANCE'),false);assert.ok(dom.body.find('dialog')[0]?.open);
 } finally { root?.dispose();active?.dispose();dom.restore(); }
});

test('unverified wallet can read administrator payout list, detail and reference FX without executing commands',async()=>{
 const dom=installPanelDocument();let root,guarded,reads=0,writes=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getSupportPayouts:async()=>{reads++;return {items:[]};},getSupportPayout:async()=>{reads++;return {id:'p1'};},getFxRate:async()=>{reads++;return {rate:'7'};},supportPayoutCommand:async()=>{writes++;}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();assert.ok(guarded);
  await Promise.all([guarded.getSupportPayouts(),guarded.getSupportPayout('p1'),guarded.getFxRate()]);
  assert.equal(reads,3);assert.equal(writes,0);assert.equal(dom.body.find('dialog').length,0);
 }finally{root?.dispose();dom.restore();}
});

test('explicit payout command requests wallet verification and never executes or replays until resubmitted',async()=>{
 const dom=installPanelDocument();let root,guarded,writes=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),verifyWalletAccess:async()=>panelStatus(),supportPayoutCommand:async()=>{writes++;return {status:'CLAIMED'};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();await assert.rejects(guarded.supportPayoutCommand('p1','begin-payment'),{code:'WALLET_ACCESS_REQUIRED'});
  assert.equal(writes,0);const dialog=dom.body.find('dialog')[0];assert.ok(dialog?.open);
  const input=dialog.find('input')[0];input.value='test-proof';await dialog.find('form')[0].handlers.submit({preventDefault(){}});
  assert.equal(writes,0);assert.equal(input.value,'');await guarded.supportPayoutCommand('p1','begin-payment');assert.equal(writes,1);
 }finally{root?.dispose();dom.restore();}
});

test('real payout panel loads through wallet access wrapper before operation verification',async()=>{
 const {supportPayoutPanel}=await import('../src/admin-support-payout-panel.js');const dom=installPanelDocument();let root,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getSupportPayouts:async()=>{reads++;return {items:[{id:'payout-read-integration',status:'REQUESTED',processing_stage:'REQUESTED',amount:'70.00',final_receive:'10.000000',can_claim:true}]};},getFxRate:async()=>({rate:'7'})},{actor:{id:'a'},renderContent:api=>supportPayoutPanel(api,{actor:{id:'a'},canOperate:true})});
  await settle();await settle();await settle();assert.equal(reads,1);assert.ok(root.find('button').some(x=>x.textContent==='处理请求'));
  assert.equal(root.find('p').some(x=>x.textContent.startsWith('提现列表加载失败')),false);
 }finally{root?.dispose();dom.restore();}
});

test('payout query waits for focus authorization recheck without warning',async()=>{
 const dom=installPanelDocument();let root,guarded,release,checks=0,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>++checks===1?Promise.resolve(panelStatus()):new Promise(r=>release=r),getSupportPayouts:async()=>{reads++;return {items:[]};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();dom.focus();const read=guarded.getSupportPayouts();read.catch(()=>{});await settle();assert.equal(reads,0);
  release(panelStatus());assert.deepEqual(await read,{items:[]});assert.equal(reads,1);
 }finally{root?.dispose();dom.restore();}
});

test('only a stale GET is fetched again after healthy focus recheck',async()=>{
 const dom=installPanelDocument();let root,guarded,release,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus(),getSupportPayouts:()=>++reads===1?new Promise(r=>release=r):Promise.resolve({items:['current']})},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();const read=guarded.getSupportPayouts();read.catch(()=>{});await settle();assert.equal(reads,1);dom.focus();await settle();release({items:['stale']});
  assert.deepEqual(await read,{items:['current']});assert.equal(reads,2);
 }finally{root?.dispose();dom.restore();}
});

test('one explicitly supplied cancellation password satisfies grant and fresh operation proof',async()=>{
 const dom=installPanelDocument();let root,guarded,verifies=0,commands=0;
 const body={proof:{operation_password:'single-test-proof'},expected_version:1};
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),verifyWalletAccess:async proof=>{verifies++;assert.deepEqual(proof,body.proof);return panelStatus();},supportPayoutCommand:async(id,action,payload)=>{commands++;assert.equal(action,'cancel-unstarted');assert.equal(payload,body);return {status:'CANCELLED'};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();assert.deepEqual(await guarded.supportPayoutCommand('p1','cancel-unstarted',body),{status:'CANCELLED'});
  assert.equal(verifies,1);assert.equal(commands,1);assert.equal(dom.body.find('dialog').length,0);
 }finally{root?.dispose();dom.restore();}
});

test('claim and heartbeat use the live session without asking for a wallet password',async()=>{
 const dom=installPanelDocument();let root,guarded,calls=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),supportPayoutCommand:async()=>{calls++;return {status:'CLAIMED'};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();await guarded.supportPayoutCommand('p1','claim',{});await guarded.supportPayoutCommand('p1','heartbeat',{});assert.equal(calls,2);assert.equal(dom.body.find('dialog').length,0);
 }finally{root?.dispose();dom.restore();}
});

test('server authorization denial is never retried as a stale GET',async()=>{
 const dom=installPanelDocument();let root,guarded,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus(),getSupportPayouts:async()=>{reads++;throw {status:403,code:'PERMISSION_DENIED'};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();await assert.rejects(guarded.getSupportPayouts(),{code:'PERMISSION_DENIED'});assert.equal(reads,1);
 }finally{root?.dispose();dom.restore();}
});

test('failed single-password verification never sends a cancellation',async()=>{
 const dom=installPanelDocument();let root,guarded,commands=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),verifyWalletAccess:async()=>{throw {status:403,code:'OPERATION_PASSWORD_INVALID'};},supportPayoutCommand:async()=>{commands++;}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();await assert.rejects(guarded.supportPayoutCommand('p1','cancel-unstarted',{proof:{operation_password:'wrong-test-proof'}}));assert.equal(commands,0);
 }finally{root?.dispose();dom.restore();}
});

test('query waits for periodic check and sends only one fresh GET',async()=>{
 const interval=globalThis.setInterval;let poll;globalThis.setInterval=fn=>{poll=fn;return {unref(){}};};
 const dom=installPanelDocument();let root,guarded,release,checks=0,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>++checks===1?Promise.resolve(panelStatus()):new Promise(r=>release=r),getSupportPayouts:async()=>{reads++;return {items:[]};}},{actor:{id:'a'},renderContent:api=>{guarded=api;return new PanelElement('article');}});
  await settle();await settle();poll();const read=guarded.getSupportPayouts();read.catch(()=>{});await settle();assert.equal(reads,0);release(panelStatus());await read;assert.equal(reads,1);
 }finally{root?.dispose();dom.restore();globalThis.setInterval=interval;}
});

test('actual payout cancellation asks for one password and sends one financial command',async()=>{
 const {supportPayoutPanel}=await import('../src/admin-support-payout-panel.js');const dom=installPanelDocument();let root,verifies=0;const commands=[];
 const order={id:'single-password-cancel',status:'REQUESTED',processing_stage:'REQUESTED',amount:'70.00',final_receive:'10.000000',version:1,claim_version:1,can_claim:true,can_cancel:true};
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getSupportPayouts:async()=>({items:[order]}),getFxRate:async()=>({rate:'7'}),getWalletOperationSecurity:async()=>({auth_mode:'operation_password'}),verifyWalletAccess:async proof=>{verifies++;assert.equal(proof.operation_password,'single-ui-proof');return panelStatus();},supportPayoutCommand:async(id,action,body)=>{commands.push(action);if(action==='cancel-unstarted')assert.equal(body.proof.operation_password,'single-ui-proof');return {...order,status:action==='cancel-unstarted'?'CANCELLED':'CLAIMED',processing_stage:'CLAIMED',can_claim:false,can_cancel:action!=='cancel-unstarted',claim_token:'fixture-lease'};}},{actor:{id:'a'},renderContent:api=>supportPayoutPanel(api,{actor:{id:'a'},canOperate:true})});
  await settle();await settle();root.find('button').find(x=>x.textContent==='处理请求').handlers.click();await settle();await settle();assert.equal(verifies,0);
  root.find('button').find(x=>x.textContent==='取消提现').handlers.click();await settle();await settle();
  const proof=root.find('input').find(x=>x.type==='password');assert.ok(proof);proof.value='single-ui-proof';proof.handlers.input();root.find('button').find(x=>x.textContent==='验证并确认本次操作').handlers.click();await settle();await settle();
  assert.equal(proof.value,'');assert.equal(verifies,1);assert.deepEqual(commands,['claim','cancel-unstarted']);assert.equal(dom.body.find('dialog').length,0);
 }finally{root?.dispose();dom.restore();}
});
