import {selectDownloadRoute, DOWNLOAD_PROBE_BUDGET_MS} from './download-network-selector.js';

const DIRECT = 'https://www.liuhetong888.com';
const FALLBACK = '/downloads/latest-arm64.apk';
const REGISTRY_MS = 2000;
const TOTAL_MS = REGISTRY_MS + DOWNLOAD_PROBE_BUDGET_MS;

export function validateAndroidRegistry(value, cdnHost) {
  if (!/^d[a-z0-9]+\.cloudfront\.net$/.test(cdnHost) || !value || value.platform !== 'android'
      || !/^\d+\.\d+\.\d+$/.test(value.version) || !Number.isSafeInteger(value.build) || value.build <= 0
      || !Number.isSafeInteger(value.artifact_bytes) || value.artifact_bytes <= 0
      || !/^[a-f0-9]{64}$/.test(value.sha256)) throw Error('Invalid release registry');
  const path = `/downloads/ChatFlow-${value.version}-build${value.build}-arm64.apk`;
  if (value.direct_url !== DIRECT + path || value.cdn_url !== `https://${cdnHost}${path}`)
    throw Error('Invalid release routes');
  return {artifactBytes:value.artifact_bytes,
    candidates:[{id:'cdn',url:value.cdn_url},{id:'direct',url:value.direct_url}]};
}

async function boundedRegistry(response) {
  if (!response.ok || !response.body || Number(response.headers?.get('content-length') ?? 0) > 32768)
    throw Error('Registry unavailable');
  const reader = response.body.getReader();
  let size = 0;
  const chunks=[];
  try {
    while (true) {
      const {done,value}=await reader.read();
      if (done) break;
      size+=value.byteLength;
      if (size>32768) throw Error('Registry too large');
      chunks.push(value);
    }
    const bytes=new Uint8Array(size);let offset=0;
    for (const chunk of chunks) {bytes.set(chunk,offset);offset+=chunk.byteLength;}
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } finally {try {await reader.cancel();} catch { /* No transport details are retained. */ }}
}

export async function runNetworkDownload({cdnHost,fetchImpl=globalThis.fetch,
    selectRoute=selectDownloadRoute,navigate=url=>window.location.assign(url),status,
    now=()=>performance.now(),signal}) {
  const started=now();
  const controller=new AbortController();
  const abort=()=>controller.abort();
  signal?.addEventListener('abort',abort,{once:true});
  let timer;
  let selected={id:'direct',url:FALLBACK,reason:'fallback'};
  let release;
  if (status) status.textContent='正在选择下载线路…';
  try {
    if(signal?.aborted) throw Error('Download cancelled');
    const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>{
      controller.abort();reject(Error('Registry timeout'));
    },REGISTRY_MS);});
    const value=await Promise.race([fetchImpl('/downloads/android-release.json',{
      cache:'no-store',credentials:'omit',redirect:'error',signal:controller.signal
    }).then(boundedRegistry),timeout]);
    clearTimeout(timer);
    release=validateAndroidRegistry(value,cdnHost);
    const direct=release.candidates.find(candidate=>candidate.id==='direct');
    selected={...direct,reason:'fallback'};
    const remaining=Math.min(DOWNLOAD_PROBE_BUDGET_MS,TOTAL_MS-(now()-started));
    if (remaining>0) {
      const result=await selectRoute({candidates:release.candidates,artifactBytes:release.artifactBytes,
        fetchImpl,now,budgetMs:remaining,signal});
      if (release.candidates.some(candidate=>candidate.id===result.id && candidate.url===result.url))
        selected={id:result.id,url:result.url,reason:result.reason};
    }
  } catch { /* Keep a fixed, usable direct route; never display raw exceptions. */ }
  finally {clearTimeout(timer);signal?.removeEventListener('abort',abort);controller.abort();}
  if(signal?.aborted) {
    if(status)status.textContent='可重新点击下载，或选择“备用下载”。';
    return {...selected,cancelled:true};
  }
  if (status) status.textContent='正在开始下载。如未开始，请点击“备用下载”。';
  try {navigate(selected.url);} catch {
    if (status) status.textContent='请点击“备用下载”继续。';
  }
  return selected;
}

export function installAndroidNetworkDownload({document,location,autoStart=false,device}) {
  if (typeof globalThis.AbortController!=='function' || typeof globalThis.fetch!=='function') return false;
  const button=document.getElementById('android-network-download');
  const cdnHost=button?.dataset.cdnHost;
  if (!cdnHost || !/^d[a-z0-9]+\.cloudfront\.net$/.test(cdnHost)) return false;
  const status=document.getElementById('download-status');
  let busy=false;
  let cached;
  let active;
  const connection=device?.connection;
  connection?.addEventListener?.('change',()=>{cached=undefined;active?.abort();});
  document.getElementById('android-direct-download')?.addEventListener('click',()=>active?.abort());
  async function download() {
    if (busy) return;
    if (cached && performance.now()-cached.at<30000) {
      try {location.assign(cached.result.url);} catch {if(status)status.textContent='请点击“备用下载”继续。';}
      return;
    }
    busy=true;active=new AbortController();button.setAttribute('aria-busy','true');
    try {
      const result=await runNetworkDownload({cdnHost,status,signal:active.signal,navigate:url=>location.assign(url)});
      if (!result.cancelled && result.reason==='fastest-stable') cached={at:performance.now(),result};
    } finally {busy=false;active=undefined;button.removeAttribute('aria-busy');}
  }
  button.addEventListener('click',event=>{event.preventDefault();void download();});
  if (autoStart) void download();
  return true;
}
