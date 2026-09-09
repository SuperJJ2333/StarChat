import {spawn} from 'node:child_process';
import {writeFile,mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
const out=resolve('../docs/verification/artifacts/2026-09-08/admin-modernization');await mkdir(out,{recursive:true});
const proc=spawn('C:/Program Files/Google/Chrome/Application/chrome.exe',['--headless=new','--disable-gpu','--no-sandbox','--remote-debugging-port=9417',`--user-data-dir=${out}/cdp-profile`],{windowsHide:true,stdio:'ignore'});
let ws;const pause=ms=>new Promise(r=>setTimeout(r,ms));
try{
 let tab;for(let i=0;i<100;i++){try{tab=await (await fetch('http://127.0.0.1:9417/json/new?about:blank',{method:'PUT'})).json();break;}catch{await pause(50);}}
 if(!tab)throw Error('Chrome did not start');ws=new WebSocket(tab.webSocketDebuggerUrl);await new Promise(r=>ws.addEventListener('open',r,{once:true}));
 let id=0;const callbacks=new Map();ws.addEventListener('message',e=>{const m=JSON.parse(e.data);if(callbacks.has(m.id)){const {resolve,reject}=callbacks.get(m.id);callbacks.delete(m.id);m.error?reject(Error(m.error.message)):resolve(m.result);}});
 const send=(method,params={})=>new Promise((resolve,reject)=>{const key=++id;callbacks.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));});
 for(const [name,width,height,path] of [['overview',1440,1100,'?overview'],['wallet',1440,1100,''],['mobile',390,844,'?overview'],['reauth',1440,1100,'reauth']]){
  await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<500});await send('Page.navigate',{url:path==='reauth'?'http://127.0.0.1:4417/tests/manual-wallet-reauth-browser.html':`http://127.0.0.1:4417/tests/admin-modern-browser.html${path}`});
  let result;for(let i=0;i<100;i++){await pause(50);result=await send('Runtime.evaluate',{expression:'JSON.stringify({status:document.body?.dataset.verification,width:innerWidth,scroll:document.documentElement.scrollWidth,text:document.body?.innerText})',returnByValue:true});if(JSON.parse(result.result.value??'{}').status)break;}
  const evidence=JSON.parse(result.result.value);await writeFile(`${out}/cdp-${name}.json`,JSON.stringify(evidence,null,2));if(evidence.status!=='PASS')throw Error(`${name}: ${evidence.text}`);
  await pause(300);const png=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await writeFile(`${out}/${name}.png`,Buffer.from(png.data,'base64'));process.stdout.write(`${name} ${width}px: PASS\n`);
 }
 await send('Browser.close');
}finally{ws?.close();proc.kill();}
