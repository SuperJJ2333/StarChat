import test from 'node:test';
import assert from 'node:assert/strict';
import {createStaffActivationApi} from '../src/admin-staff-activation.js';

test('activation gateway sends credentials only to fixed same-origin purpose endpoints',async()=>{
 const calls=[];
 const api=createStaffActivationApi({fetchImpl:async(path,options)=>{calls.push([path,options]);return {ok:true,json:async()=>({status:'activated'})};}});
 await api.requestStaffActivation({username:'staff',password:'synthetic',challenge_id:'opaque',captcha_answer:'123456'});
 await api.confirmStaffActivation({activation_id:'opaque',code:'123456'});
 assert.equal(calls[0][0],'/api/v1/auth/staff-activation/challenges');
 assert.equal(calls[1][0],'/api/v1/auth/staff-activation/confirm');
 for(const [,options] of calls){assert.equal(options.credentials,'same-origin');assert.equal(options.cache,'no-store');assert.equal(options.headers['X-Admin-CSRF'],'1');}
});

test('activation never automatically repeats a lost or denied request',async()=>{
 let calls=0;
 const api=createStaffActivationApi({fetchImpl:async()=>{calls++;throw Error('offline');}});
 await assert.rejects(api.requestStaffActivation({}),/不会自动重发/);
 assert.equal(calls,1);
 const denied=createStaffActivationApi({fetchImpl:async()=>({ok:false,status:403,json:async()=>({error:{code:'STAFF_ACTIVATION_INVALID',message:'身份无效'}})})});
 await assert.rejects(denied.confirmStaffActivation({}),error=>error.code==='STAFF_ACTIVATION_INVALID'&&error.status===403);
});
