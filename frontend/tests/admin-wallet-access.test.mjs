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
