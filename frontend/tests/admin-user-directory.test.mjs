import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';

class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';}
  append(...items){this.children.push(...items);}
  replaceChildren(...items){this.children=items;}
  setAttribute(key,value){this[key]=value;}
  addEventListener(key,handler){this.handlers[key]=handler;}
  find(tag){return [this,...this.children.flatMap(item=>item.find?.(tag)??[])].filter(item=>item.tag===tag);}
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const account={id:'user-1',username:'chat0001',nickname:'小星',status:'ACTIVE',email:'a@example.test',email_verified_at:'2026-09-20T00:00:00Z',phone:'+8613800000000',phone_verified_at:null,caibi_balance:'100000000000000001.09',official_support_title:'客服主管'};
async function setup(api){
  assert.ok(existsSync(new URL('../src/admin-user-directory.js',import.meta.url)),'administrator user directory exists');
  globalThis.document={createElement:tag=>new Element(tag)};
  const {userDirectory}=await import('../src/admin-user-directory.js');
  const panel=userDirectory(api);await settle();return panel;
}

test('administrator directory shows exact contact and balance fields from its dedicated endpoint',async()=>{
  const calls=[];const panel=await setup({searchUsers:async query=>{calls.push(query);return {items:[account],total:1,next_cursor:null};}});
  assert.deepEqual(calls,[{q:'',limit:50,cursor:null}]);
  assert.deepEqual(panel.find('th').map(item=>item.textContent),['畅聊号','昵称','邮箱','手机号','点钻余额','账号状态','客服头衔']);
  const cells=panel.find('td').map(item=>item.textContent);
  assert.ok(cells.includes('chat0001'));assert.ok(cells.some(value=>value.includes('a@example.test')));
  assert.ok(cells.some(value=>value.includes('+8613800000000')));
  assert.ok(cells.includes('100,000,000,000,000,001.09'));
  assert.ok(cells.includes('客服主管'));
});

test('directory search and cursor navigation ignore a stale response',async()=>{
  const requests=[];const pending=[];
  const panel=await setup({searchUsers:query=>{requests.push(query);return new Promise(resolve=>pending.push(resolve));}});
  const search=panel.find('input').find(item=>item.name==='q');search.value='new@example.test';
  const form=panel.find('form')[0];form.handlers.submit({preventDefault(){}});
  pending[1]({items:[{...account,username:'new'}],total:100,next_cursor:'opaque'});await settle();
  pending[0]({items:[{...account,username:'old'}],total:1,next_cursor:null});await settle();
  assert.ok(panel.find('td').some(item=>item.textContent==='new'));
  assert.ok(!panel.find('td').some(item=>item.textContent==='old'));
  await panel.find('button').find(item=>item.textContent==='下一页').handlers.click();
  assert.deepEqual(requests.at(-1),{q:'new@example.test',limit:50,cursor:'opaque'});
  panel.dispose();
});

test('failed directory search keeps the displayed page and offers explicit retry',async()=>{
  let fail=false;const requests=[];
  const panel=await setup({searchUsers:async query=>{requests.push(query);if(fail)throw Error('offline');return {items:[account],total:1,next_cursor:null};}});
  const search=panel.find('input').find(item=>item.name==='q');search.value='nobody';fail=true;
  await panel.find('form')[0].handlers.submit({preventDefault(){}});
  assert.ok(panel.find('td').some(item=>item.textContent==='chat0001'));
  fail=false;await panel.find('button').find(item=>item.textContent==='重新加载').handlers.click();
  assert.deepEqual(requests.at(-1),{q:'nobody',limit:50,cursor:null});
  assert.ok(panel.find('td').some(item=>item.textContent==='chat0001'));
});

test('permission loss clears previously displayed contacts and balances',async()=>{
  let denied=false;
  const panel=await setup({searchUsers:async()=>{if(denied)throw Object.assign(Error('没有访问权限'),{status:403,code:'FORBIDDEN'});return {items:[account],total:1,next_cursor:null};}});
  assert.ok(panel.find('td').some(item=>item.textContent?.includes('a@example.test')));
  denied=true;await panel.refresh();
  assert.equal(panel.find('td').some(item=>item.textContent?.includes('a@example.test')),false);
  assert.equal(panel.find('td').some(item=>item.textContent?.includes('100,000,000,000,000,001.09')),false);
});
