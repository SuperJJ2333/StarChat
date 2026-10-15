import test from 'node:test';
import assert from 'node:assert/strict';
import { getScreen } from '../src/catalog/screens.js';

class Node extends EventTarget {
  constructor(tag) { super(); this.tagName=tag; this.children=[]; this.attributes={}; this.dataset={}; this.textContent=''; }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children=[...nodes]; }
  setAttribute(key,value) { this.attributes[key]=String(value); }
}
globalThis.HTMLElement=Node;
globalThis.document={createElement: tag=>new Node(tag)};
const walk=node=>[node,...node.children.flatMap(walk)];
const control=(root,id)=>walk(root).find(node=>node.dataset.control===id);
const click=(root,id)=>{ const node=control(root,id); assert.ok(node, id); node.dispatchEvent(new Event('click')); };
const render=async state=>{
  const {mobileExperienceDemo}=await import('../src/screens/mobile-experience.js');
  return mobileExperienceDemo(getScreen(`chat-experience-${state}`));
};

test('cached content stays present while asynchronous sync fails and retries',async()=>{
  const root=await render('cached-start');
  const rows=()=>walk(root).filter(node=>node.dataset.cachedMessage);
  assert.equal(rows().length,3);
  assert.ok(rows().every(node=>!node.tagName.startsWith('app-')), 'custom components reject unregistered data attributes');
  assert.equal(walk(root).filter(node=>node.className==='c-conversation-row').length,3);
  click(root,'fail'); assert.equal(rows().length,3);
  click(root,'retry'); assert.equal(rows().length,3);
  click(root,'complete'); assert.equal(root.dataset.phase,'ready');
});
test('local outgoing preview survives failure/retry and one ACK maps the same row',async()=>{
  const root=await render('outgoing-media');
  const identity=root.dataset.transactionId;
  const preview=control(root,'preview');
  assert.ok(preview.attributes.src);
  const spinner=control(root,'progress');
  assert.ok(spinner);
  assert.equal(spinner.hidden,false);
  click(root,'fail'); assert.ok(control(root,'retry'));
  assert.equal(spinner.hidden,true);
  click(root,'retry'); assert.equal(root.dataset.transactionId,identity);
  assert.equal(spinner.hidden,false);
  click(root,'complete'); assert.equal(control(root,'preview'),preview);
  assert.equal(spinner.hidden,true);
  assert.equal(root.dataset.phase,'sent');
  assert.equal(walk(root).some(node=>node.textContent.includes('待发附件')),false);
});
test('super emoji begins static and playback is an explicit reversible action',async()=>{
  const root=await render('static-emoji');
  assert.equal(root.dataset.phase,'static');
  click(root,'play'); assert.equal(root.dataset.phase,'playing');
  click(root,'stop'); assert.equal(root.dataset.phase,'static');
});
test('deferred notification permission remains requestable without claiming granted',async()=>{
  const root=await render('notification-permission');
  click(root,'defer'); assert.equal(root.dataset.phase,'deferred');
  click(root,'request'); assert.equal(root.dataset.phase,'requesting');
  click(root,'deny'); assert.equal(root.dataset.phase,'denied');
  assert.ok(control(root,'settings'));
  click(root,'settings'); assert.equal(root.dataset.phase,'settings');
  click(root,'grant'); assert.equal(root.dataset.phase,'granted');
});
