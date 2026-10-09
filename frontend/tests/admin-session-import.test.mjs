import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
test('admin home and API share the exact session module URL',async()=>{
 const sources=await Promise.all(['admin-home.js','admin-api.js'].map(name=>readFile(new URL('../src/'+name,import.meta.url),'utf8')));
 const urls=sources.map(source=>source.match(/from\s+["']([^"']*admin-session\.js[^"']*)["']/)?.[1]);
 assert.ok(urls.every(Boolean)); assert.equal(urls[0],urls[1]);
});

test('payout entry retains administrator gating, guarded API and session-bound wallet checks',async()=>{
 const source=await readFile(new URL('../src/admin-home.js',import.meta.url),'utf8');
 const section=source.slice(source.indexOf('function supportOrderContent('),source.indexOf('function walletContent('));
 assert.match(section,/onOpenPayout:can\(context,'\*'\)\?showPayout:null/);
 assert.match(section,/showPayout=\(\)=>\{if\(!can\(context,'\*'\)\)return/);
 assert.match(section,/walletAccessPanel\(browserAdminApi\(\)/);
 assert.match(section,/renderContent:guarded=>supportPayoutPanel\(guarded/);
 assert.match(section,/expectedCacheEpoch:adminSession\.cacheEpoch\(\),getCacheEpoch:\(\)=>adminSession\.cacheEpoch\(\)/);
});
