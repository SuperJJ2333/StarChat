import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const run=promisify(execFile),out=resolve('../docs/verification/artifacts/2026-09-08/admin-modernization');
await mkdir(out,{recursive:true});
const chrome='C:/Program Files/Google/Chrome/Application/chrome.exe';
for(const [name,width,height,path] of [['overview',1440,1100,'?overview'],['wallet',1440,1100,''],['mobile',390,844,'?overview']]){
 const {stdout}=await run(chrome,['--headless=new','--disable-gpu','--no-sandbox',`--user-data-dir=${out}/profile-${name}`,`--window-size=${width},${height}`,'--virtual-time-budget=8000',`--screenshot=${out}/${name}.png`,'--dump-dom',`http://127.0.0.1:4417/tests/admin-modern-browser.html${path}`],{maxBuffer:8*1024*1024});
 await writeFile(`${out}/browser-${name}.html`,stdout);
 if(!stdout.includes('data-verification="PASS"'))throw Error(`${name} browser verification failed; see saved DOM`);
 process.stdout.write(`${name}: PASS\n`);
}
