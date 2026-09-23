import test from 'node:test';
import assert from 'node:assert/strict';
import {createOrderFeed,orderNotifications} from '../src/admin-order-notifications.js';

class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.attributes={};this.dataset={};this.hidden=false;}
  append(...items){this.children.push(...items);}
  setAttribute(key,value){this.attributes[key]=value;}
  addEventListener(key,handler){this.handlers[key]=handler;}
  find(cls){return this.className?.split(' ').includes(cls)?this:this.children.map(c=>c.find?.(cls)).find(Boolean);}
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
function setup(){
  globalThis.document={hidden:false,createElement:tag=>new Element(tag),createElementNS:(_,tag)=>new Element(tag),addEventListener(){},removeEventListener(){}};
  const values=new Map();return {getItem:key=>values.get(key),setItem:(key,value)=>values.set(key,value),values};
}
const event=(id,type='recharge.submitted')=>({id,event_type:type,kind:type.startsWith('recharge')?'recharge':'payout',order_id:id});

test('bootstrap drains history silently and persists opaque cursor per actor; live new orders alone count',async()=>{
  const storage=setup(),calls=[],changes=[];
  const pages=[{items:Array.from({length:100},(_,i)=>event(`old${i}`)),next_cursor:'opaque-a'},
    {items:[event('old101')],next_cursor:'opaque-b'},
    {items:[event('new'),event('status','recharge.claimed'),event('payout','wallet.manual_payout_request')],next_cursor:'opaque-c'}];
  const api={getOrderEvents:async params=>{calls.push(params);return pages.shift()??{items:[]};}};
  const root=orderNotifications(api,{actorId:'staff-a',storage,onChange:items=>changes.push(...items)});
  await settle();assert.equal(calls.length,2);assert.equal(root.find('admin-notification-count').hidden,true);
  await root.refresh();assert.equal(root.find('admin-notification-count').textContent,'2');assert.equal(changes.length,104);
  root.find('admin-notification-bell').handlers.click();assert.equal(root.find('admin-notification-count').hidden,true);
  root.dispose();const again=orderNotifications(api,{actorId:'staff-a',storage});await settle();again.dispose();
  assert.equal(calls.at(-1).cursor,'opaque-c');
  const other=orderNotifications(api,{actorId:'staff-b',storage});await settle();other.dispose();assert.equal(calls.at(-1).cursor,undefined);
});

test('network interruption recovers, forbidden stops, and disposed request cannot notify',async()=>{
  setup();let mode='empty',finish,calls=0;
  const api={getOrderEvents:async()=>{calls++;if(mode==='offline')throw Error('offline');if(mode==='forbidden')throw {status:403};if(mode==='late')return new Promise(resolve=>{finish=resolve;});return {items:[]};}};
  const root=orderNotifications(api);await settle();mode='offline';await root.refresh();assert.equal(root.find('admin-notification-error').hidden,false);
  mode='empty';await root.refresh();assert.equal(root.find('admin-notification-error').hidden,true);
  mode='forbidden';await root.refresh();const count=calls;await root.refresh();assert.equal(calls,count);assert.match(root.find('admin-notification-error').textContent,/权限/);root.dispose();
  mode='late';const late=orderNotifications(api);late.dispose();finish({items:[event('late')],next_cursor:'late'});await settle();assert.equal(late.find('admin-notification-count').hidden,true);
});

test('feed retries failed consumer and ignores late rejection after dispose',async()=>{
  let fail=true,errors=0;const received=[];
  const feed=createOrderFeed({getOrderEvents:async()=>({items:[event('one')],next_cursor:'cursor'})},{visible:()=>true,onEvents:items=>{if(fail)throw Error('render');received.push(...items);},onError:()=>errors++});
  await feed.poll();fail=false;await feed.poll();await feed.poll();assert.equal(received.length,1);assert.equal(errors,1);feed.dispose();
  let reject;const late=createOrderFeed({getOrderEvents:()=>new Promise((_,r)=>{reject=r;})},{visible:()=>true,onError:()=>errors++});const pending=late.poll();late.dispose();reject(Error('late'));await pending;assert.equal(errors,1);
});

test('invalid saved cursor rebaselines silently and close dismisses without marking unread',async()=>{
  const storage=setup(),calls=[];
  storage.setItem('starchat.order-notifications.v1:a',JSON.stringify({cursor:'expired',unread:0}));
  const pages=[{status:400},{items:[event('historical')],next_cursor:'baseline'},{items:[event('live')],next_cursor:'live-cursor'}];
  const root=orderNotifications({getOrderEvents:async params=>{calls.push(params);const page=pages.shift();if(page.status)throw page;return page;}},{actorId:'a',storage});
  await settle();await root.refresh();assert.equal(calls[1].cursor,undefined);assert.equal(root.find('admin-notification-count').hidden,true);
  await root.refresh();const toast=root.find('admin-notification-toast');assert.equal(toast.hidden,false);
  toast.find('admin-notification-toast-actions').children[1].handlers.click();assert.equal(toast.hidden,true);assert.equal(root.find('admin-notification-count').textContent,'1');
  root.markRead();assert.equal(root.find('admin-notification-count').hidden,true);root.dispose();
});

test('empty baseline survives reload and unread survives reload without replay toast',async()=>{
  const storage=setup();let page={items:[],next_cursor:null};
  const api={getOrderEvents:async()=>page};
  const first=orderNotifications(api,{actorId:'empty',storage});await settle();first.dispose();
  page={items:[event('first-ever')],next_cursor:'first-position'};
  const second=orderNotifications(api,{actorId:'empty',storage});await settle();assert.equal(second.find('admin-notification-count').textContent,'1');second.dispose();
  page={items:[],next_cursor:'first-position'};
  const third=orderNotifications(api,{actorId:'empty',storage});await settle();assert.equal(third.find('admin-notification-count').textContent,'1');assert.equal(third.find('admin-notification-toast').hidden,true);third.dispose();
});
