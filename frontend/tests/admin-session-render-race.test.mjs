import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const chrome=['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe','C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'].find(existsSync);
const pause=()=>new Promise(resolve=>setTimeout(resolve,50));
async function jsonReady(url){
  for(let i=0;i<100;i++){try{const response=await fetch(url);if(response.ok)return await response.json();}catch{}await pause();}
  throw Error('browser did not become ready');
}
test('session change prevents an old in-flight context response from rebuilding the admin page',{timeout:45000},async t=>{
  assert.ok(chrome,'Chrome or Edge is required');
  const port=5700+process.pid%1000,debugPort=7700+process.pid%1000,origin=`http://127.0.0.1:${port}`;
  const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:new URL('../',import.meta.url),env:{...process.env,PORT:String(port)},stdio:'ignore'});
  t.after(()=>server.kill());
  for(let i=0;i<100;i++){try{if((await fetch(origin)).ok)break;}catch{}await pause();}
  const browser=spawn(chrome,['--headless=new','--disable-gpu','--no-sandbox','--no-first-run',`--user-data-dir=${join(tmpdir(),`starchat-session-render-${process.pid}`)}`,`--remote-debugging-port=${debugPort}`,'about:blank'],{stdio:'ignore'});
  t.after(()=>browser.kill());
  await jsonReady(`http://127.0.0.1:${debugPort}/json/version`);
  const pages=await jsonReady(`http://127.0.0.1:${debugPort}/json`),page=pages.find(item=>item.type==='page');
  assert.ok(page?.webSocketDebuggerUrl);
  const socket=new WebSocket(page.webSocketDebuggerUrl);t.after(()=>socket.close());
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let serial=0;const pending=new Map();
  socket.addEventListener('message',event=>{const message=JSON.parse(String(event.data)),waiter=pending.get(message.id);if(!waiter)return;pending.delete(message.id);message.error?waiter.reject(Error(message.error.message)):waiter.resolve(message.result);});
  const call=(method,params={})=>new Promise((resolve,reject)=>{const id=++serial;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params}));});
  await call('Page.navigate',{url:`${origin}/tests/admin-session-render-race-browser.html`});
  let state;const deadline=Date.now()+15000;
  while(Date.now()<deadline){const response=await call('Runtime.evaluate',{expression:"({result:document.body?.dataset.result,message:document.querySelector('#result')?.textContent})",returnByValue:true});state=response.result?.value;if(state?.result==='PASS'||state?.result==='FAIL')break;await pause();}
  assert.equal(state?.result,'PASS',state?.message??'fixture did not finish');
});
