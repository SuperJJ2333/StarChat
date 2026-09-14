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
