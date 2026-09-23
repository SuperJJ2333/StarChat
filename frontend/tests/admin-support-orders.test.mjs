import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';
import {createOrderFeed} from '../src/admin-order-notifications.js';

test('support commands use actual encoded routes, token and idempotency',async()=>{
  const calls=[];const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>({})};}});
  await api.claimRecharge('a/b',{idempotencyKey:'claim'});
  await api.heartbeatRecharge('a/b',{claim_token:'lease'},{idempotencyKey:'heartbeat'});
  await api.verifyRechargePayment('a/b',{claim_token:'lease',txid:'proof',log_index:0},{idempotencyKey:'proof'});
  await api.prepareRechargeSettlement('a/b',{claim_token:'lease',final_rate:'7'},{idempotencyKey:'settle'});
  await api.executeRechargeSettlement('a/b',{claim_token:'lease'},{idempotencyKey:'execute'});
  await api.getOrderEvents({cursor:'event 1',limit:100});
  assert.deepEqual(calls.slice(0,5).map(c=>c.url),['claim','heartbeat','verify-payment','prepare-settlement','execute-settlement'].map(action=>`/api/v1/recharge/admin/requests/a%2Fb/${action}`));
  assert.equal(JSON.parse(calls[2].options.body).claim_token,'lease');
  assert.equal(calls[3].options.headers['Idempotency-Key'],'settle');
  assert.equal(new URL(calls[5].url,'https://test').searchParams.get('cursor'),'event 1');
});

test('notification cursor survives failure, deduplicates replay, skips hidden and stops on forbidden',async()=>{
  let hidden=false,mode=0;const calls=[],events=[];
  const feed=createOrderFeed({getOrderEvents:async filters=>{calls.push(filters);if(mode===1)throw new Error('offline');if(mode===3)throw {status:403};return {items:[{id:'e1'},{id:mode===2?'e2':'e1'}],next_cursor:mode===2?'e2':'e1'};}},{visible:()=>!hidden,onEvents:items=>events.push(...items)});
  await feed.poll();mode=1;await feed.poll();mode=2;await feed.poll();
  assert.deepEqual(events.map(e=>e.id),['e1','e2']);assert.equal(calls[2].cursor,'e1');
  hidden=true;await feed.poll();assert.equal(calls.length,3);
  hidden=false;mode=3;await feed.poll();mode=2;await feed.poll();assert.equal(calls.length,4);
});

test('support-order verification uses its own scope and configured password schema',async()=>{
  const calls=[];const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>({})};}});
  await api.getSupportOrderAccess();await api.verifySupportOrderAccess({operation_password:'isolated-proof'});
  await api.setSupportOrderPassword({login_password:'isolated-login',new_operation_password:'isolated-new'},{idempotencyKey:'setup'});
  assert.equal(calls[0].url,'/api/v1/admin/support-orders/security');
  assert.equal(calls[1].url,'/api/v1/admin/support-orders/security/verify');
  assert.equal(calls[2].options.method,'PUT');assert.equal(calls[2].options.headers['Idempotency-Key'],'setup');
});

test('independent approval methods call existing ledger review routes',async()=>{
  const calls=[];const api=createAdminApi({fetchImpl:async(url,options)=>{calls.push({url,options});return {ok:true,json:async()=>({status:'ADMIN_APPROVED'})};}});
  await api.financeReviewAdjustment('adj/1',{approve:true},{idempotencyKey:'finance'});
  await api.adminReviewAdjustment('adj/1',{approve:false},{idempotencyKey:'admin'});
  assert.deepEqual(calls.map(call=>call.url),['/api/v1/ledger/adjustments/adj%2F1/finance-review','/api/v1/ledger/adjustments/adj%2F1/admin-review']);
  assert.deepEqual(JSON.parse(calls[1].options.body),{approve:false});
});
