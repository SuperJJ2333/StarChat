import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';

class Element {
  constructor(tag) {this.tag=tag;this.children=[];this.handlers={};this.value='';this.dataset={};}
  append(...children){this.children.push(...children);}
  replaceChildren(...children){this.children=children;}
  setAttribute(name,value){this[name]=value;}
  addEventListener(name,handler){this.handlers[name]=handler;}
  focus(){}
  find(tag){return [this,...this.children.flatMap(child=>child.find?.(tag)??[])].filter(item=>item.tag===tag);}
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const row={id:'internal-uuid',username:'chat123',nickname:'小星',status:'ACTIVE',created_at:'2026-09-10T00:00:00Z',email_verified_at:null};
async function setup(api,options={}) {
  assert.ok(existsSync(new URL('../src/admin-user-panel.js',import.meta.url)),'user panel is implemented');
  globalThis.document={createElement:tag=>new Element(tag)};
  const {userPanel}=await import('../src/admin-user-panel.js');
  const panel=userPanel(api,{context:{permissions:['admin.bans.read']},...options});await settle();return panel;
}
const click=(panel,label)=>panel.find('button').find(x=>x.textContent===label).handlers.click();
const submit=(panel,name)=>panel.find('form').find(x=>x.name===name).handlers.submit({preventDefault(){}});

test('security uses Chinese selections and submits selected internal identity only on confirmation',async()=>{
  const calls=[];let reads=0;
  const panel=await setup({getModule:async()=>{reads++;return {items:[row],total:1};},command:async(...args)=>{calls.push(args);return {status:'ACTIVE'};}});
  assert.deepEqual(panel.find('select').filter(x=>x.name).map(x=>x.name),['target_type','reason_code','duration_minutes']);
  assert.equal(calls.length,0);click(panel,'选择封禁');assert.equal(calls.length,0);
  assert.ok(panel.find('input').some(x=>x.value==='小星（chat123）'));
  await submit(panel,'ban-user');
  assert.equal(calls[0][0],'/api/v1/admin/security/bans');
  assert.deepEqual(calls[0][1],{target_type:'user',target:'internal-uuid',reason_code:'POLICY_VIOLATION',duration_minutes:1440});
  assert.ok(calls[0][2].idempotencyKey);assert.equal(reads,2);
});

test('server search and cursor pages never let an older response replace a newer query',async()=>{
  const calls=[],pending=[];
  const panel=await setup({getModule:(_module,query)=>{calls.push(query);return new Promise(resolve=>pending.push(resolve));}},{module:'analytics'});
  const search=panel.find('input').find(x=>x.name==='q');search.value='new';submit(panel,'user-search');
  pending[1]({items:[{...row,username:'new'}],total:2,next_cursor:'opaque'});await settle();
  pending[0]({items:[{...row,username:'old'}],total:1});await settle();
  assert.ok(panel.find('td').some(x=>x.textContent==='new'));assert.ok(!panel.find('td').some(x=>x.textContent==='old'));
  click(panel,'下一页');assert.deepEqual(calls.at(-1),{q:'new',limit:10,cursor:'opaque'});
  assert.equal(panel.find('form').some(x=>x.name==='ban-user'),false);panel.dispose();
});

test('reauthentication preserves selection and never automatically submits the ban',async()=>{
  let writes=0,reauth=0;
  const panel=await setup({getModule:async()=>({items:[row],total:1}),command:async()=>{writes++;throw {code:'RECENT_LOGIN_REQUIRED',status:403,message:'验证身份'};}},{onReauthenticate:async()=>{reauth++;return true;}});
  click(panel,'选择封禁');await submit(panel,'ban-user');await click(panel,'验证身份');
  assert.equal(reauth,1);assert.equal(writes,1);assert.ok(panel.find('input').some(x=>x.value==='小星（chat123）'));
});

test('uncertain command result retains draft and cannot be retried',async()=>{
  let writes=0;
  const panel=await setup({getModule:async()=>({items:[row],total:1}),command:async()=>{writes++;throw {code:'NETWORK_ERROR',status:0};}});
  click(panel,'选择封禁');await submit(panel,'ban-user');await submit(panel,'ban-user');
  assert.equal(writes,1);assert.equal(panel.find('button').find(x=>x.textContent==='确认封禁').disabled,true);
  assert.ok(panel.find('input').some(x=>x.value==='小星（chat123）'));
});

test('read-only analytics displays exact user columns and no command controls',async()=>{
  const panel=await setup({getModule:async()=>({items:[row],total:1})},{module:'analytics'});
  assert.deepEqual(panel.find('th').map(x=>x.textContent),['注册时间','畅聊号','用户名','邮箱验证','账号状态']);
  assert.ok(panel.find('td').some(x=>x.textContent==='2026-09-10 08:00:00'));
  assert.equal(panel.find('select').filter(x=>x.name).length,0);
});

test('active user and IP bans revoke the exact observed round',async()=>{
  globalThis.confirm=()=>true;const calls=[];
  const record={id:'ip-ban',target_type:'ip',target:'192.0.2.12',starts_at:'2026-09-30T01:00:00+00:00'};
  const panel=await setup({getModule:async()=>({items:[{...row,status:'SUSPENDED',active_ban:{id:'user-ban',starts_at:record.starts_at}}],total:1}),getActiveBans:async()=>({items:[record],total:1}),command:async(...args)=>{calls.push(args);return {status:'REVOKED'};}});
  await settle();assert.equal(panel.find('button').filter(x=>x.textContent==='选择封禁').length,0);
  const buttons=panel.find('button').filter(x=>x.textContent==='解除封禁');assert.equal(buttons.length,2);
  await buttons[1].handlers.click();assert.equal(calls[0][0],'/api/v1/admin/security/bans/ip-ban/revoke');assert.equal(calls[0][1].expected_starts_at,record.starts_at);
});

test('failed next page preserves committed page and retry advances exactly once',async()=>{
  const calls=[];let fail=true;
  const panel=await setup({getModule:async(_module,query)=>{calls.push(query);if(query.cursor==='second'&&fail)throw Error('offline');return query.cursor?{items:[{...row,username:'page-two'}],total:100}:{items:[row],total:100,next_cursor:'second'};}},{module:'analytics'});
  click(panel,'下一页');await settle();
  assert.ok(panel.find('span').some(x=>x.textContent==='第 1 页 · 共 100 位用户'));
  assert.equal(panel.find('button').find(x=>x.textContent==='上一页').disabled,true);
  fail=false;click(panel,'重新加载');await settle();
  assert.deepEqual(calls.at(-1),{q:'',limit:10,cursor:'second'});
  assert.ok(panel.find('span').some(x=>x.textContent==='第 2 页 · 共 100 位用户'));
  click(panel,'上一页');await settle();
  assert.equal(calls.at(-1).cursor,undefined);
});

test('failed search keeps old query cursors for next page and retries the failed search explicitly',async()=>{
  const calls=[];let fail=true;
  const panel=await setup({getModule:async(_module,query)=>{calls.push(query);if(query.q==='new'&&fail)throw Error('offline');return {items:[row],total:100,next_cursor:query.cursor?null:'old-next'};}},{module:'analytics'});
  panel.find('input').find(x=>x.name==='q').value='new';await submit(panel,'user-search');
  assert.equal(panel.find('button').find(x=>x.textContent==='下一页').disabled,false);
  click(panel,'下一页');await settle();
  assert.deepEqual(calls.at(-1),{q:'',limit:10,cursor:'old-next'});
  await submit(panel,'user-search');fail=false;click(panel,'重新加载');await settle();
  assert.deepEqual(calls.at(-1),{q:'new',limit:10,cursor:undefined});
  assert.ok(panel.find('span').some(x=>x.textContent==='第 1 页 · 共 100 位用户'));
});

test('creating a ban refreshes the active user and IP ban list',async()=>{
 let bansReads=0;
 const panel=await setup({getModule:async()=>({items:[row],total:1}),getActiveBans:async()=>{bansReads++;return {items:[],total:0};},command:async()=>({status:'ACTIVE'})});
 click(panel,'选择封禁');await submit(panel,'ban-user');assert.equal(bansReads,2);
});
