import test from "node:test";
import assert from "node:assert/strict";
import { createAdminApi, can, normalizeAdminContext } from "../src/admin-api.js";
import { readFile } from "node:fs/promises";

test('admin module reads encode literal user search and opaque cursor without replacing bearer',async()=>{
  let received;
  const api=createAdminApi({token:'access',fetchImpl:async(url,options)=>{received={url,options};return new Response('{}');}});
  await api.getModule('security',{q:'小星+a@example.test',limit:50,cursor:'cursor+/='});
  const url=new URL(received.url,'https://example.test');
  assert.equal(url.searchParams.get('q'),'小星+a@example.test');
  assert.equal(url.searchParams.get('cursor'),'cursor+/=');
  assert.equal(url.searchParams.get('limit'),'50');
  assert.equal(received.options.headers.Authorization,'Bearer access');
  assert.equal(received.options.cache,'no-store');
});

test('admin errors preserve structured handover evidence for actionable feedback',async()=>{
  const fields=[{loc:['evidence'],msg:'MANUAL_COVERAGE_PENDING',type:'wallet.handover.evidence'}];
  const api=createAdminApi({fetchImpl:async()=>new Response(JSON.stringify({error:{code:'HANDOVER_EVIDENCE_UNAVAILABLE',fields}}),{status:503})});
  await assert.rejects(api.getContext(),error=>{
    assert.deepEqual(error.fields,fields);return true;
  });
});

test('session expiry emits once per failed request; permission denial and stale responses do not', async()=>{
  const events=[];globalThis.dispatchEvent=e=>events.push(e.type);globalThis.sessionStorage={getItem:()=> 'current'};
  try {
    for(const [token,status,code] of [['current',401,'UNAUTHORIZED'],['current',403,'RECENT_LOGIN_REQUIRED'],['current',403,'FORBIDDEN'],['stale',401,'UNAUTHORIZED']]){
      const api=createAdminApi({token,fetchImpl:async()=>new Response(JSON.stringify({error:{code}}),{status,headers:{'content-type':'application/json'}})});
      await assert.rejects(api.getContext());
    }
    assert.deepEqual(events,['admin-session-expired']); // Recent-auth is an inline step-up, not a logout.
  } finally {delete globalThis.dispatchEvent;delete globalThis.sessionStorage;}
});

test("admin API sends bearer token and parses permissions", async () => {
  const calls=[];
  const api=createAdminApi({baseUrl:"https://chatflow.test", token:"abc", fetchImpl: async (url,opts)=>{calls.push({url,opts}); return new Response(JSON.stringify({permissions:["admin.dashboard.read"], overview:{registered_users:42}}),{status:200,headers:{"content-type":"application/json"}});}});
  const result=await api.getContext();
  assert.equal(calls[0].url,"https://chatflow.test/api/v1/admin/context");
  assert.equal(calls[0].opts.headers.Authorization,"Bearer abc");
  assert.equal(result.overview.registered_users,42);
  assert.equal(can(result,"admin.dashboard.read"),true);
});

test("admin API normalizes forbidden response as authorization error", async ()=>{
  const api=createAdminApi({fetchImpl: async ()=>new Response(JSON.stringify({code:"FORBIDDEN",message:"denied"}),{status:403})});
  await assert.rejects(api.getContext(), e=>e.code==="FORBIDDEN" && e.status===403);
});

test("admin API context defaults to empty collections without fixtures", ()=>{
  const value=normalizeAdminContext({permissions:[]});
  assert.deepEqual(value.permissions,[]);
  assert.deepEqual(value.modules,{});
});

test("admin API performs official login and module reads", async () => {
  const calls=[];
  const api=createAdminApi({baseUrl:"https://chatflow.test",fetchImpl:async (url,opts)=>{calls.push({url,opts});if(url.endsWith("/auth/login"))return new Response(JSON.stringify({access_token:"access",refresh_token:"refresh"}),{status:200,headers:{"content-type":"application/json"}});return new Response(JSON.stringify({items:[{id:"row-1"}]}),{status:200,headers:{"content-type":"application/json"}});}});
  const tokens=await api.login({username:"admin",password:"secret",device_key:"browser",device_name:"ChatFlow Admin"});
  assert.equal(tokens.access_token,"access");
  const rows=await api.getModule("ledger","access");
  assert.equal(rows.items[0].id,"row-1");
  assert.equal(calls[0].opts.method,"POST");
  assert.equal(calls[1].opts.headers.Authorization,"Bearer access");
});

test("admin API sends an idempotency header for direct admin commands", async () => {
  let received;
  const api=createAdminApi({fetchImpl:async (_url, options)=>{received=options;return new Response(JSON.stringify({id:"ok"}),{status:201,headers:{"content-type":"application/json"}})}});
  await api.command("/api/v1/admin/ads", {advertiser_name:"Demo"}, {idempotencyKey:"id-1"});
  assert.equal(received.headers["Idempotency-Key"],"id-1");
});

test("admin finance command posts a two-decimal direct grant payload", async () => {
  let received;
  const api=createAdminApi({fetchImpl:async (url, options)=>{received={url,options};return new Response(JSON.stringify({amount:"88.00",status:"POSTED"}),{status:201,headers:{"content-type":"application/json"}})}});
  const result=await api.command("/api/v1/admin/finance/adjustments", {user_id:"support-1",amount:88,reason_code:"SUPPORT_CAIBI_GRANT"}, {idempotencyKey:"grant-1"});
  assert.equal(received.url,"/api/v1/admin/finance/adjustments");
  assert.deepEqual(JSON.parse(received.options.body),{user_id:"support-1",amount:88,reason_code:"SUPPORT_CAIBI_GRANT"});
  assert.equal(result.amount,"88.00");
});

test("module heading appends a heading node instead of stringifying it", async () => {
  const source = await readFile(new URL("../src/admin-home.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /element\("div", null, element\("h2"/u);
});

test("admin finance form exposes a direct point-grant flow rather than an application ID", async () => {
  const source = await readFile(new URL("../src/admin-home.js", import.meta.url), "utf8");
  assert.match(source, /客服用户 ID/u);
  assert.match(source, /发放数量（点钻）/u);
  assert.match(source, /finance:"\/api\/v1\/admin\/finance\/adjustments"/u);
  assert.doesNotMatch(source, /finance:\[\["request_id","点钻申请 ID"\]\]/u);
});

test("admin API unwraps production error envelopes", async () => {
  const api=createAdminApi({fetchImpl:async ()=>new Response(JSON.stringify({error:{code:"VALIDATION_ERROR",message:"请求参数无效"}}),{status:422,headers:{"content-type":"application/json"}})});
  await assert.rejects(api.command("/api/v1/admin/ads", {}, {idempotencyKey:"error-1"}), error => error.code === "VALIDATION_ERROR" && error.message === "请求参数无效");
});

test('network failure has a safe localized error and never replays a password command',async()=>{
 let calls=0;
 const api=createAdminApi({fetchImpl:async()=>{calls++;throw new TypeError('Failed to fetch');}});
 await assert.rejects(api.setWalletOperationPassword({login_password:'synthetic-login',new_operation_password:'synthetic-operation'},{idempotencyKey:'network-test'}),error=>error.code==='NETWORK_ERROR'&&error.status===0&&error.message.includes('网络'));
 assert.equal(calls,1);
});
