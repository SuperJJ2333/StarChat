import test from 'node:test';
import assert from 'node:assert/strict';
import { getScreen } from '../src/catalog/screens.js';

class Node extends EventTarget {
  constructor(tag) { super(); this.tagName=tag; this.children=[]; this.attributes={}; this.dataset={}; this.className=''; this.textContent=''; this.classList={add: v=>{this.className+=` ${v}`;}}; }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children=[...nodes]; }
  setAttribute(k,v) { this.attributes[k]=String(v); }
  getAttribute(k) { return this.attributes[k] ?? null; }
}
const all = n => [n,...n.children.flatMap(all)];
async function dom(run) {
  const oldDocument=globalThis.document, oldElement=globalThis.HTMLElement;
  globalThis.HTMLElement=Node;
  globalThis.document={createElement: t=>new Node(t),createElementNS: (_,t)=>new Node(t)};
  try { await run(); } finally { globalThis.document=oldDocument; globalThis.HTMLElement=oldElement; }
}

test('video camera toggle changes transmission preview and survives minimize/restore',()=>dom(async()=>{
  const {renderScreen}=await import('../src/screens/calls.js');
  const screen=renderScreen(getScreen('calls-video-connected'));
  const find=k=>all(screen).find(n=>n.dataset.control===k);
  const camera=find('camera-toggle');
  assert.ok(camera,'dedicated camera toggle');
  assert.equal(camera.attributes['aria-label'],'关闭摄像头');
  camera.dispatchEvent(new Event('click')); await Promise.resolve();
  assert.equal(camera.attributes['aria-label'],'开启摄像头');
  assert.equal(find('local-video').hidden,true);
  find('minimize').dispatchEvent(new Event('click'));
  const mini=find('return-call');
  assert.ok(mini.attributes.image);
  assert.equal(mini.attributes.duration,'00:42');
  mini.dispatchEvent(new Event('click'));
  assert.equal(find('local-video').hidden,true);
  assert.equal(camera.attributes['aria-label'],'开启摄像头');
}));

test('audio floating entry restores the same custom peer avatar',()=>dom(async()=>{
  const {renderScreen}=await import('../src/screens/calls.js');
  const screen=renderScreen(getScreen('calls-audio-minimized'));
  const mini=all(screen).find(n=>n.dataset.control==='return-call');
  const image=mini.attributes.image;
  assert.ok(image);
  mini.dispatchEvent(new Event('click'));
  assert.ok(all(screen).some(n=>n.tagName==='app-avatar' && n.attributes.image===image));
}));

test('notification demo does not replay seen messages and shows a group avatar for a new message',()=>dom(async()=>{
  const {notificationAvatarDemo}=await import('../src/screens/notification-avatar.js');
  const screen=notificationAvatarDemo({module:'messages',page:'notification',state:'viewed',title:'消息提醒'});
  assert.equal(all(screen).some(n=>n.dataset.notification==='visible'),false);
  const fresh=all(screen).find(n=>n.dataset.control==='new-message');
  fresh.dispatchEvent(new Event('click'));
  const banner=all(screen).find(n=>n.dataset.notification==='visible');
  assert.ok(banner);
  assert.ok(all(banner).some(n=>n.tagName==='app-avatar' && n.attributes.image));
}));

test('shared return card shows peer avatar, media type and a waiting or elapsed caption',()=>dom(async()=>{
  const {AppCallReturn}=await import('../src/components/call-return.js');
  const card=new AppCallReturn();
  card.setAttribute('name','周然'); card.setAttribute('image','./assets/demo-peer-avatar.svg');
  card.setAttribute('video','true'); card.setAttribute('duration','01:12');
  let body=card.render();
  assert.ok(all(body).some(n=>n.tagName==='app-avatar' && n.attributes.image==='./assets/demo-peer-avatar.svg'));
  assert.ok(all(body).some(n=>n.textContent==='01:12'));
  card.setAttribute('waiting','true'); body=card.render();
  assert.ok(all(body).some(n=>n.textContent==='等待接通'));
}));
