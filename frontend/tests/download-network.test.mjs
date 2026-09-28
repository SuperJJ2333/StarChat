import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';
import test from 'node:test';

const path = new URL('../src/download-network.js', import.meta.url);
let mod;
if (existsSync(path)) mod = await import(path.href);
const host = 'dexamplenetwork.cloudfront.net';
const release = () => ({platform:'android',version:'0.4.19',build:2188,artifact_bytes:81505310,
  sha256:'aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220',
  cdn_url:`https://${host}/downloads/ChatFlow-0.4.19-build2188-arm64.apk`,
  direct_url:'https://www.liuhetong888.com/downloads/ChatFlow-0.4.19-build2188-arm64.apk'});
const api = () => {assert.ok(mod, 'download bootstrap is missing'); return mod;};

test('registry binds both routes to exact pinned host and same immutable version', () => {
  const r=release();
  assert.deepEqual(api().validateAndroidRegistry(r, host).candidates,
    [{id:'cdn',url:r.cdn_url},{id:'direct',url:r.direct_url}]);
});

for (const [name,change] of Object.entries({
  foreign:{cdn_url:'https://evil.invalid/downloads/ChatFlow-0.4.19-build2188-arm64.apk'},
  otherCdn:{cdn_url:'https://dother.cloudfront.net/downloads/ChatFlow-0.4.19-build2188-arm64.apk'},
  stale:{cdn_url:`https://${host}/downloads/ChatFlow-0.4.16-build2185-arm64.apk`},
  mutable:{direct_url:'https://www.liuhetong888.com/downloads/latest-arm64.apk'},
  query:{cdn_url:`https://${host}/downloads/ChatFlow-0.4.19-build2188-arm64.apk?url=evil`},
  credential:{cdn_url:`https://name:pass@${host}/downloads/ChatFlow-0.4.19-build2188-arm64.apk`},
  ios:{platform:'ios'}, size:{artifact_bytes:'81505310'}, hash:{sha256:'not-a-digest'}
})) test(`registry rejects ${name} before any probing`,()=>{
  const {validateAndroidRegistry}=api();
  assert.throws(()=>validateAndroidRegistry({...release(),...change},host));
});

test('download loads bounded registry before selection and never accepts selector foreign URL',async()=>{
  const r=release(); let probes=0; const target=[];
  const result=await api().runNetworkDownload({cdnHost:host,fetchImpl:async()=>new Response(JSON.stringify(r)),
    selectRoute:async()=>{probes++;return {url:'https://evil.invalid',id:'cdn'};},
    navigate:url=>target.push(url)});
  assert.equal(probes,1); assert.equal(result.id,'direct');
  assert.deepEqual(target,[r.direct_url]);
});

test('failed registry falls back immediately without probing or leaving a pending UI',async()=>{
  let probes=0;const target=[];
  const result=await api().runNetworkDownload({cdnHost:host,fetchImpl:async()=>{throw Error('private transport details');},
    selectRoute:async()=>{probes++;},navigate:url=>target.push(url)});
  assert.equal(probes,0); assert.equal(result.id,'direct');
  assert.deepEqual(target,['/downloads/latest-arm64.apk']);
});

test('oversized registry is canceled before JSON parsing and no external request follows',async()=>{
  let canceled=false;let reads=0;const targets=[];
  const response={ok:true,body:{getReader:()=>({async read(){reads++;return {done:false,value:new Uint8Array(32769)};},async cancel(){canceled=true;}})}};
  const result=await api().runNetworkDownload({cdnHost:host,fetchImpl:async()=>response,
    selectRoute:async()=>assert.fail('must not probe'),navigate:url=>targets.push(url)});
  assert.equal(result.id,'direct');assert.equal(reads,1);assert.equal(canceled,true);
});

test('valid measured route is used and status avoids promising sustained speed',async()=>{
  const r=release();const status={textContent:''};let target;
  const result=await api().runNetworkDownload({cdnHost:host,fetchImpl:async()=>new Response(JSON.stringify(r)),
    selectRoute:async opts=>{assert.equal(opts.artifactBytes,r.artifact_bytes);assert.ok(opts.budgetMs<=5000);return {id:'cdn',url:r.cdn_url};},
    status,navigate:url=>{target=url;}});
  assert.equal(result.id,'cdn');assert.equal(target,r.cdn_url);
  assert.match(status.textContent,/备用/);assert.doesNotMatch(status.textContent,/保证|全球最快/);
});

test('manual backup cancels probing without launching a second download',async()=>{
  const r=release();const controller=new AbortController();let launches=0;
  const result=await api().runNetworkDownload({cdnHost:host,signal:controller.signal,
    fetchImpl:async()=>new Response(JSON.stringify(r)),
    selectRoute:async opts=>{assert.equal(opts.signal,controller.signal);controller.abort();return {id:'cdn',url:r.cdn_url};},
    navigate:()=>{launches++;}});
  assert.equal(launches,0);assert.equal(result.cancelled,true);
});

test('exhausted overall budget uses exact direct route without starting any probes',async()=>{
  const r=release();let ticks=0;let probes=0;const targets=[];
  await api().runNetworkDownload({cdnHost:host,now:()=>ticks++===0?0:6000,
    fetchImpl:async()=>new Response(JSON.stringify(r)),
    selectRoute:async()=>{probes++;return {id:'cdn',url:r.cdn_url};},
    navigate:url=>targets.push(url)});
  assert.equal(probes,0);assert.deepEqual(targets,[r.direct_url]);
});

for(const missing of ['AbortController','fetch']) test(`missing ${missing} retains native download before intercepting click`,()=>{
  const original=globalThis[missing];let handlers=0;
  const button={dataset:{cdnHost:host},addEventListener(){handlers++;}};
  try {
    globalThis[missing]=undefined;
    assert.equal(api().installAndroidNetworkDownload({
      document:{getElementById:id=>id==='android-network-download'?button:null},location:{}}),false);
    assert.equal(handlers,0);
  } finally {globalThis[missing]=original;}
});
