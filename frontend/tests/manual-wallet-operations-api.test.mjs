import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';
test('manual incident actions use scoped operations routes and stable keys; reads use authenticated no-store',async()=>{
 const calls=[];const api=createAdminApi({token:'fixture',fetchImpl:async(url,options)=>{calls.push({url,options});return new Response('{}',{headers:{'content-type':'application/json'}});}});
 await api.getWalletIncidents({cursor:'opaque/x'}); await api.getWalletIncident('id/x'); await api.getWalletMonitorStatus();
 for(const action of ['ack','review','resolve']) await api.manualWalletIncidentAction('id/x',action,{expected_version:2,mfa_proof:'123456'},{idempotencyKey:'stable'});
 assert.equal(calls[0].url,'/api/v1/admin/wallet/incidents?limit=25&cursor=opaque%2Fx');
 for(const call of calls) {assert.equal(call.options.cache,'no-store');assert.equal(call.options.headers.Authorization,'Bearer fixture');}
 assert.equal(calls[4].url,'/api/v1/admin/wallet/manual/operations/incidents/id%2Fx/review');
 assert.equal(calls[5].options.headers['Idempotency-Key'],'stable');
 await assert.rejects(api.manualWalletIncidentAction('id','resume',{}, {idempotencyKey:'no'}));
 await assert.rejects(api.manualWalletIncidentAction('id','ack',{})); assert.equal(calls.length,6);
});
