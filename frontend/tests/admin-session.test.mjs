import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminSession} from '../src/admin-session.js';
const reply=token=>new Response(JSON.stringify({access_token:token,expires_in:900,user_id:'fixture',session_id:'family'}),{status:200});

test('staff password login uses dedicated endpoint and the same in-memory session lifecycle',async()=>{
 const calls=[];const session=createAdminSession({fetchImpl:async(path,options)=>{calls.push({path,options});return reply('staff-access');}});
 await session.staffLogin({username:'staff',password:'fixture'});
 assert.equal(calls[0].path,'/api/v1/auth/staff-login');assert.equal(calls[0].options.credentials,'same-origin');
 assert.equal(calls[0].options.headers['X-Admin-CSRF'],'1');assert.equal(await session.getToken(),'staff-access');
 session.clear();await assert.rejects(session.getToken(),e=>e.status===401);
});
test('staff shared-password change uses the bound management session and clears local access on success',async()=>{
 const calls=[];
 const session=createAdminSession({fetchImpl:async(path,options)=>{
   calls.push({path,options});
   return path.endsWith('/staff-password')?new Response(null,{status:204}):reply('staff-access');
 }});
 await session.staffLogin({username:'staff',password:'old-password'});
 await session.changeStaffPassword({current_password:'old-password',new_password:'new-password-123'});
 assert.equal(calls[1].path,'/api/v1/auth/admin-session/staff-password');
 assert.equal(calls[1].options.credentials,'same-origin');
 assert.equal(calls[1].options.headers['X-Admin-CSRF'],'1');
 assert.equal(calls[1].options.headers['X-Admin-Session'],'family');
 assert.equal(calls[1].options.headers.Authorization,'Bearer staff-access');
 assert.equal(session.peek(),null);
 await assert.rejects(session.getToken(),error=>error.status===401);
});
test('session bootstraps with protected cookie and coalesces refresh',async()=>{
  const calls=[];let done;const session=createAdminSession({fetchImpl:(path,options)=>{calls.push({path,options});return new Promise(r=>done=r);}});
  const a=session.getToken(),b=session.getToken();await Promise.resolve();done(reply('access'));assert.equal(await a,'access');assert.equal(await b,'access');
  assert.equal(calls.length,1);assert.equal(calls[0].options.credentials,'same-origin');assert.equal(calls[0].options.headers['X-Admin-CSRF'],'1');assert.equal(await session.getToken(),'access');
});
test('failed mutation response is never retried by session manager',async()=>{
  let calls=0;const session=createAdminSession({fetchImpl:async()=>{calls++;throw Error('lost');}});
  await assert.rejects(session.login({password:'fixture'}));assert.equal(calls,1);
});
test('invalidating a session discards late refresh results',async()=>{
  let finish;const session=createAdminSession({fetchImpl:()=>new Promise(r=>finish=r)});
  const loading=session.getToken();await Promise.resolve();session.clear();finish(reply('stale'));
  await assert.rejects(loading);assert.equal(session.peek(),null);
});
test('failed expired-cookie refresh clears the active session on check',async()=>{
  let time=0,calls=0;const session=createAdminSession({now:()=>time,fetchImpl:async()=>++calls===1?reply('old'):new Response('{}',{status:401})});
  await session.getToken();time=901000;await assert.rejects(session.check());assert.equal(session.peek(),null);
});
test('refresh cannot switch the identity underneath an existing page',async()=>{
  let time=0,calls=0;const session=createAdminSession({now:()=>time,fetchImpl:async()=>new Response(JSON.stringify({access_token:++calls===1?'alice':'bob',expires_in:900,user_id:calls===1?'alice':'bob',session_id:calls===1?'a':'b'}))});
  await session.getToken();time=901000;await assert.rejects(session.getToken(),e=>e.code==='ADMIN_SESSION_CHANGED');assert.equal(session.peek(),null);
});
test('logout failure invalidates context and forbids implicit bootstrap of another cookie',async()=>{
 let calls=0;const session=createAdminSession({fetchImpl:async()=>++calls===1?reply('alice'):new Response('{}',{status:401})});await session.getToken();await assert.rejects(session.logout());await assert.rejects(session.getToken(),e=>e.status===401);assert.equal(calls,2);
});
test('wallet cache epoch belongs to one management identity and survives token refresh only',async()=>{
 let time=0,calls=0;
 const session=createAdminSession({now:()=>time,fetchImpl:async()=>reply(`token-${++calls}`)});
 assert.equal(session.cacheEpoch(),null);
 await session.getToken();const epoch=session.cacheEpoch();
 assert.equal(typeof epoch,'number');
 time=901000;await session.getToken();
 assert.equal(session.cacheEpoch(),epoch,'renewing the same management session retains its in-memory view epoch');
 session.clear();assert.equal(session.cacheEpoch(),null);
 await session.login({username:'administrator',password:'fixture'});
 assert.notEqual(session.cacheEpoch(),epoch,'a new login cannot inherit the prior wallet view');
});
test('an in-flight login cannot tag an old wallet view with the next session epoch',async()=>{
 let calls=0,finish;
 const session=createAdminSession({fetchImpl:async()=>++calls===1?reply('old'):new Promise(resolve=>{finish=resolve;})});
 await session.getToken();const oldEpoch=session.cacheEpoch();
 const login=session.login({username:'administrator',password:'fixture'});
 assert.equal(session.cacheEpoch(),null,'wallet read cache is disabled while identity replacement is pending');
 await Promise.resolve();finish(reply('new'));await login;
 assert.notEqual(session.cacheEpoch(),oldEpoch);
});

test('a same-origin tab login invalidates another tab without echoing the change back',async()=>{
 const peers=[];
 const channelFactory=()=>{const channel={onmessage:null,postMessage(message){for(const peer of peers)if(peer!==channel)queueMicrotask(()=>peer.onmessage?.({data:message}));}};peers.push(channel);return channel;};
 let externalChanges=0;
 const response=async(path)=>new Response(JSON.stringify({access_token:'fixture',expires_in:900,user_id:'owner',session_id:path.endsWith('/admin-login')?'new-session':'old-session'}));
 const first=createAdminSession({fetchImpl:response,channelFactory});
 const second=createAdminSession({fetchImpl:response,channelFactory,onExternalChange:()=>externalChanges++});
 await first.getToken();await second.getToken();
 const oldEpoch=second.cacheEpoch();
 await first.login({username:'owner',password:'fixture'});
 await Promise.resolve();
 assert.equal(second.cacheEpoch(),null,'old tab loses its wallet cache immediately after another tab logs in');
 assert.equal(second.peek(),null);
 assert.notEqual(first.cacheEpoch(),null,'the new session is not invalidated by a broadcast echo');
 assert.equal(externalChanges,1);
 assert.equal(typeof oldEpoch,'number');
});

test('logout broadcasts before its network response so another tab hides wallet data promptly',async()=>{
 const peers=[];
 const channelFactory=()=>{const channel={onmessage:null,postMessage(message){for(const peer of peers)if(peer!==channel)queueMicrotask(()=>peer.onmessage?.({data:message}));}};peers.push(channel);return channel;};
 let finishLogout,externalChanges=0;
 const response=(path)=>path.endsWith('/logout')?new Promise(resolve=>{finishLogout=resolve;}):reply('old');
 const first=createAdminSession({fetchImpl:response,channelFactory});
 const second=createAdminSession({fetchImpl:response,channelFactory,onExternalChange:()=>externalChanges++});
 await first.getToken();await second.getToken();
 const logout=first.logout();await Promise.resolve();
 assert.equal(second.cacheEpoch(),null);
 assert.equal(externalChanges,1);
 finishLogout(new Response(null,{status:204}));await logout;
});

test('another tab login invalidates a pending old-cookie bootstrap before it can reveal wallet data',async()=>{
 const peers=[];
 const channelFactory=()=>{const channel={onmessage:null,postMessage(message){for(const peer of peers)if(peer!==channel)queueMicrotask(()=>peer.onmessage?.({data:message}));}};peers.push(channel);return channel;};
 let finishOldRefresh;
 const oldTab=createAdminSession({channelFactory,fetchImpl:()=>new Promise(resolve=>{finishOldRefresh=resolve;})});
 const newTab=createAdminSession({channelFactory,fetchImpl:async()=>new Response(JSON.stringify({access_token:'new-token',expires_in:900,user_id:'other',session_id:'new-session'}))});
 const oldBootstrap=oldTab.getToken();
 await Promise.resolve();
 await newTab.login({username:'other',password:'fixture'});
 await Promise.resolve();
 finishOldRefresh(new Response(JSON.stringify({access_token:'old-token',expires_in:900,user_id:'owner',session_id:'old-session'})));
 await assert.rejects(oldBootstrap,/管理会话已变化/u);
 assert.equal(oldTab.peek(),null);
 assert.equal(oldTab.cacheEpoch(),null);
 assert.notEqual(newTab.cacheEpoch(),null);
});
