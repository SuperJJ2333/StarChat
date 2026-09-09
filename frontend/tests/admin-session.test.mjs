import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminSession} from '../src/admin-session.js';
const reply=token=>new Response(JSON.stringify({access_token:token,expires_in:900,user_id:'fixture',session_id:'family'}),{status:200});
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
