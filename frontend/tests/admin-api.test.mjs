import test from "node:test";
import assert from "node:assert/strict";
import { createAdminApi, can, normalizeAdminContext } from "../src/admin-api.js";
import { readFile } from "node:fs/promises";

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
