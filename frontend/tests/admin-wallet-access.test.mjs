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
 return {body,app,focus:()=>listeners.get('global:focus')?.(),visibility:()=>listeners.get('document:visibilitychange')?.(),restore:()=>Object.assign(globalThis,original)};
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const panelStatus=(overrides={})=>({enabled:true,verified:true,configured:true,auth_mode:'operation_password',server_time:new Date(start).toISOString(),expires_at:new Date(start+3600000).toISOString(),...overrides});

test('confirmed owner can read without grant while write intent verifies and requires a new submit',async()=>{
 const dom=installPanelDocument();let root,viewApi,access,reads=0,writes=0,verifies=0;
 try{
  root=module.walletAccessPanel({
   getWalletAccess:async()=>panelStatus({verified:false}),
   verifyWalletAccess:async()=>{verifies++;return panelStatus();},
   getManualPayouts:async()=>{reads++;return {items:[]};},
   claimManualPayout:async()=>{writes++;return {status:'CLAIMED'};}
  },{actor:{id:'a'},renderContent:(api,controller)=>{viewApi=api;access=controller;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();
  assert.equal(root.find('article').length,1);
  assert.equal(root.find('p').some(p=>p.textContent?.includes('当前可查看钱包资料')),false);
  assert.equal(root.find('button').some(b=>b.textContent==='验证以操作'),false);
  assert.equal(access.canWrite(),false);assert.equal(access.usesGrant(),true);
  await viewApi.getManualPayouts();assert.equal(reads,1);
  await assert.rejects(viewApi.claimManualPayout('id',{},{}),{code:'WALLET_ACCESS_REQUIRED'});
  assert.equal(writes,0);
  assert.equal(await access.requestWriteGrant(),false);
  assert.equal(dom.body.find('dialog').length,1);
  const form=dom.body.find('dialog')[0].find('form')[0];
  form.find('input')[0].value='synthetic-proof';await form.handlers.submit({preventDefault(){}});await settle();
  assert.equal(verifies,1);assert.equal(access.canWrite(),true);assert.equal(writes,0);
  await viewApi.claimManualPayout('id',{},{});assert.equal(writes,1);
 }finally{root?.dispose();dom.restore();}
});

test('wallet module rows are readable without grant but other modules are not allowlisted',async()=>{
 const dom=installPanelDocument();let root,viewApi,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getModule:async name=>{reads++;return {module:name,items:[]};}},
   {actor:{id:'a'},renderContent:api=>{viewApi=api;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();
  assert.equal((await viewApi.getModule('wallet')).module,'wallet');assert.equal(reads,1);
  await assert.rejects(viewApi.getModule('users'),{code:'WALLET_ACCESS_REQUIRED'});assert.equal(reads,1);
 }finally{root?.dispose();dom.restore();}
});

test('grant expiry locks writes without rebuilding the confirmed owner view',async()=>{
 const dom=installPanelDocument();let root,article,expired=false,viewApi,access,rendered=0,disposed=0,reads=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>expired?panelStatus({verified:false}):panelStatus(),getManualPayouts:async()=>{reads++;return {items:[]};}},
   {actor:{id:'a'},renderContent:(api,controller)=>{viewApi=api;access=controller;rendered++;article=new PanelElement('article');article.dispose=()=>{disposed++;};return article;}});
  dom.app.append(root);await settle();await settle();assert.equal(access.canWrite(),true);
  expired=true;await root.refresh();assert.equal(access.canWrite(),false);
  assert.equal(rendered,1);assert.equal(disposed,0);assert.equal(root.find('article')[0],article);
  assert.equal(dom.body.find('dialog').length,0);
  await viewApi.getManualPayouts();assert.equal(reads,1);
 }finally{root?.dispose();dom.restore();}
});

test('server grant mode change rebuilds credential fields for legacy policy',async()=>{
 const dom=installPanelDocument();let root,legacy=false,rendered=0,disposed=0,usesGrant;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>legacy?{enabled:false}:panelStatus()},
   {actor:{id:'a'},renderContent:(_,controller)=>{usesGrant=controller.usesGrant();rendered++;const article=new PanelElement('article');article.dispose=()=>{disposed++;};return article;}});
  dom.app.append(root);await settle();await settle();assert.equal(usesGrant,true);
  legacy=true;await root.refresh();assert.equal(usesGrant,false);assert.equal(rendered,2);assert.equal(disposed,1);
 }finally{root?.dispose();dom.restore();}
});

test('owner change removes prior wallet data and blocks later reads',async()=>{
 const dom=installPanelDocument();let root,viewApi;
 const actor={id:'a'};
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus(),getManualPayouts:async()=>({items:[]})},
   {actor,renderContent:api=>{viewApi=api;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();assert.equal(root.find('article').length,1);
  actor.id='b';await root.refresh();assert.equal(root.find('article').length,0);
  await assert.rejects(viewApi.getManualPayouts(),{code:'WALLET_ACCESS_REQUIRED'});
 }finally{root?.dispose();dom.restore();}
});

test('failed wallet read clears stale owner data instead of showing cached balances',async()=>{
 const dom=installPanelDocument();let root,viewApi;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getManualPayouts:async()=>{throw {code:'NETWORK_ERROR',message:'offline'};}},
   {actor:{id:'a'},renderContent:api=>{viewApi=api;const article=new PanelElement('article');article.textContent='SENSITIVE-BALANCE';return article;}});
  dom.app.append(root);await settle();await settle();assert.equal(root.find('article').length,1);
  await assert.rejects(viewApi.getManualPayouts());
  assert.equal(root.find('article').length,0);
  assert.ok(dom.body.find('dialog')[0]?.open);
 }finally{root?.dispose();dom.restore();}
});

test('raw read failure clears wallet data and detached content',async()=>{
 const dom=installPanelDocument();let root,viewApi,disposed=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getManualPayouts:async()=>{throw new TypeError('raw socket failure');}},
   {actor:{id:'a'},renderContent:api=>{viewApi=api;const article=new PanelElement('article');article.textContent='SENSITIVE-BALANCE';article.dispose=()=>{disposed++;};return article;}});
  dom.app.append(root);await settle();await settle();assert.equal(root.find('article').length,1);
  await assert.rejects(viewApi.getManualPayouts(),TypeError);
  assert.equal(root.find('article').length,0);assert.equal(disposed,1);
  assert.ok(dom.body.find('dialog')[0]?.open);
  assert.ok(dom.body.find('p').some(node=>node.textContent?.includes('敏感内容已隐藏')));
  assert.equal(dom.body.find('p').some(node=>node.textContent?.includes('raw socket failure')),false);
 }finally{root?.dispose();dom.restore();}
});

test('unexpected wallet read authorization denial clears prior owner data',async()=>{
 const dom=installPanelDocument();let root,viewApi;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus({verified:false}),getManualPayouts:async()=>{throw {status:403,code:'WALLET_ACCESS_REQUIRED'};}},
   {actor:{id:'a'},renderContent:api=>{viewApi=api;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();
  await assert.rejects(viewApi.getManualPayouts());assert.equal(root.find('article').length,0);
 }finally{root?.dispose();dom.restore();}
});

test('unconfigured owner view still polls for role revocation',async()=>{
 const dom=installPanelDocument();const previousInterval=globalThis.setInterval,previousClear=globalThis.clearInterval;
 let root,poll,revoked=false;
 globalThis.setInterval=fn=>{poll=fn;return 1;};globalThis.clearInterval=()=>{};
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>{if(revoked)throw {status:403,code:'PERMISSION_DENIED'};return panelStatus({configured:false,verified:false});}},
   {actor:{id:'a'},renderContent:()=>new PanelElement('article')});
  dom.app.append(root);await settle();await settle();assert.equal(root.find('article').length,1);
  revoked=true;poll();await settle();await settle();assert.equal(root.find('article').length,0);
 }finally{root?.dispose();globalThis.setInterval=previousInterval;globalThis.clearInterval=previousClear;dom.restore();}
});

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
test('malformed or failed owner recheck clears a read-only verify state',async()=>{
 for(const failure of [()=>({enabled:true,configured:true,auth_mode:'operation_password'}),()=>{throw {status:500,code:'INTERNAL_ERROR'};}]){
  let failed=false;const f=fixture({getWalletAccess:async()=>failed?failure():panelStatus({verified:false})});
  await f.gate.check();assert.equal(f.gate.state().kind,'verify');assert.equal(f.gate.readAllowed(),true);
  failed=true;await f.gate.check();assert.equal(f.gate.state().kind,'network');assert.equal(f.gate.readAllowed(),false);
 }
});
test('a late status response cannot restore reads after an intervening permission denial',async()=>{
 let release,checks=0;const f=fixture({getWalletAccess:()=>++checks===1?Promise.resolve(status()):new Promise(resolve=>{release=resolve;})});
 await f.gate.check();const pending=f.gate.check();
 await assert.rejects(f.gate.read(async()=>{throw {status:403,code:'PERMISSION_DENIED'};}));
 assert.equal(f.gate.state().kind,'forbidden');release(status());await pending;
 assert.equal(f.gate.state().kind,'forbidden');assert.equal(f.gate.readAllowed(),false);
});
test('a repeated read-only owner status does not cancel an in-flight wallet read',async()=>{
 let release;const f=fixture({getWalletAccess:async()=>panelStatus({verified:false})});
 await f.gate.check();const reading=f.gate.read(()=>new Promise(resolve=>{release=resolve;}));
 await f.gate.check();release({items:['safe']});
 assert.deepEqual(await reading,{items:['safe']});
});

test('focus and visibility recheck suspend detached dialogs once and retain the same read view',async()=>{
 const dom=installPanelDocument();let root,article,release,checks=0,rendered=0,suspended=0,resumed=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>++checks===1?Promise.resolve(panelStatus()):new Promise(resolve=>release=resolve)},
   {actor:{id:'a'},renderContent:()=>{rendered++;article=new PanelElement('article');article.suspendForAccessCheck=()=>{suspended++;};article.resumeReadDetail=()=>{resumed++;};return article;}});
  dom.app.append(root);await settle();await settle();
  dom.focus();dom.visibility();await settle();
  assert.equal(checks,2,'focus and visibility share a pending owner check');
  assert.equal(suspended,1,'detached dialogs close before authorization is known');
  assert.equal(root.find('article')[0],article);
  assert.ok(root.children.some(child=>child.inert&&child.style.visibility==='hidden'),'sensitive view is masked during recheck');
  release(panelStatus());await settle();await settle();
  assert.equal(rendered,1);assert.equal(resumed,1);
  assert.equal(root.find('article')[0],article);
  assert.equal(root.children.some(child=>child.inert),false);
 }finally{root?.dispose();dom.restore();}
});

test('background polling keeps an authorized detail visible until a denied result clears it',async()=>{
 const dom=installPanelDocument();const originalInterval=globalThis.setInterval,originalClear=globalThis.clearInterval;
 let root,poll,release,checks=0,suspended=0,access;
 globalThis.setInterval=fn=>{poll=fn;return 1;};globalThis.clearInterval=()=>{};
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>++checks===1?Promise.resolve(panelStatus()):new Promise(resolve=>release=resolve)},
   {actor:{id:'a'},renderContent:(_,controller)=>{access=controller;const article=new PanelElement('article');article.suspendForAccessCheck=()=>{suspended++;};return article;}});
  dom.app.append(root);await settle();await settle();
  poll();await settle();
  assert.equal(checks,2);assert.equal(root.find('article').length,1);
  assert.equal(suspended,0,'background poll does not close visible detail');
  assert.equal(root.children.some(child=>child.style.visibility==='hidden'),false);
  assert.equal(access.canWrite(),false,'write actions are disabled while owner status is pending');
  release(panelStatus());await settle();await settle();
  assert.equal(root.find('article').length,1);
 }finally{root?.dispose();globalThis.setInterval=originalInterval;globalThis.clearInterval=originalClear;dom.restore();}
});
test('active focus check supersedes a hung background poll and restores writes on success',async()=>{
 const dom=installPanelDocument();const originalInterval=globalThis.setInterval,originalClear=globalThis.clearInterval;
 let root,poll,releasePoll,checks=0,access;
 globalThis.setInterval=fn=>{poll=fn;return 1;};globalThis.clearInterval=()=>{};
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>++checks===2?new Promise(resolve=>{releasePoll=resolve;}):Promise.resolve(panelStatus())},
   {actor:{id:'a'},renderContent:(_,controller)=>{access=controller;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();poll();await settle();assert.equal(access.canWrite(),false);
  dom.focus();await settle();await settle();assert.equal(checks,3);assert.equal(access.canWrite(),true,'stale poll cannot keep a new authorized view write-locked');
  releasePoll(panelStatus());await settle();assert.equal(access.canWrite(),true);
 }finally{root?.dispose();globalThis.setInterval=originalInterval;globalThis.clearInterval=originalClear;dom.restore();}
});

test('unverified or expired owner can read and opens the access dialog only for write intent',async()=>{
 for(const response of [panelStatus({verified:false}),panelStatus({expires_at:new Date(start).toISOString()})]) {
  const dom=installPanelDocument();let root,access;
  try {
   root=module.walletAccessPanel({getWalletAccess:async()=>response},{actor:{id:'a'},renderContent:(_,controller)=>{access=controller;return new PanelElement('article');}});dom.app.append(root);await settle();await settle();
   assert.equal(root.find('article').length,1);assert.equal(access.canWrite(),false);
   assert.equal(dom.body.find('dialog').length,0);assert.equal(dom.app.inert,false);
   assert.equal(await access.requestWriteGrant(),false);
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
test('only a confirmed owner can export a read snapshot and denial invalidates its shell cache',async()=>{
 const dom=installPanelDocument();let root,release,denials=0;
 try{
  root=module.walletAccessPanel({getWalletAccess:()=>new Promise(resolve=>release=resolve)},
   {actor:{id:'a'},onWalletReadDenied:()=>{denials++;},renderContent:()=>{const article=new PanelElement('article');article.exportReadView=()=>({offset:25});return article;}});
  dom.app.append(root);await settle();
  assert.equal(root.exportReadView(),null,'unconfirmed owner cannot export sensitive cache data');
  release(panelStatus({verified:false}));await settle();await settle();
  assert.deepEqual(root.exportReadView(),{offset:25},'read-only owner can export without write grant');
  let rejectStatus;root.dispose();
  root=module.walletAccessPanel({getWalletAccess:()=>new Promise((_,reject)=>{rejectStatus=reject;})},
   {actor:{id:'a'},onWalletReadDenied:()=>{denials++;},renderContent:()=>new PanelElement('article')});
  dom.app.append(root);await settle();rejectStatus({code:'NETWORK_ERROR'});await settle();await settle();
  assert.equal(root.exportReadView(),null);assert.equal(denials,1);
 }finally{root?.dispose();dom.restore();}
});
test('same-actor management session replacement clears an existing wallet view on recheck',async()=>{
 const dom=installPanelDocument();let root,epoch=1,denials=0,logins=0,viewApi;
 try{
  root=module.walletAccessPanel({getWalletAccess:async()=>panelStatus(),getManualPayouts:async()=>({items:[]})},
   {actor:{id:'a'},expectedCacheEpoch:1,getCacheEpoch:()=>epoch,onWalletReadDenied:()=>{denials++;},onLogin:()=>{logins++;},
    renderContent:api=>{viewApi=api;return new PanelElement('article');}});
  dom.app.append(root);await settle();await settle();assert.equal(root.find('article').length,1);
  epoch=2;dom.focus();await settle();await settle();
  assert.equal(root.find('article').length,0);assert.equal(root.exportReadView(),null);
  assert.equal(denials,1);assert.equal(logins,1);
  await assert.rejects(viewApi.getManualPayouts(),{code:'WALLET_ACCESS_REQUIRED'});
 }finally{root?.dispose();dom.restore();}
});
