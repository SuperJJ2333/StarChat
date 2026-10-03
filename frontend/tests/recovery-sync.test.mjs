import test from 'node:test';
import assert from 'node:assert/strict';
import {getScreen} from '../src/catalog/screens.js';
class Node {
  constructor(tag) {this.tag=tag;this.children=[];this.attributes={};this.dataset={};this.classList={add(){}};}
  append(...nodes){this.children.push(...nodes);}
  setAttribute(key,value){this.attributes[key]=String(value);}
  addEventListener(){}
}
globalThis.HTMLElement=class {};
globalThis.document={createElement:tag=>new Node(tag),createElementNS:(_,tag)=>new Node(tag)};
const walk=node=>[node,...node.children.flatMap(walk)];
test('normal settings reaches automatic recovery and every lifecycle state is truthful',async()=>{
  const settings=walk(await getScreen('profile-settings-default').component());
  assert.ok(settings.some(n=>n.attributes.title==='聊天记录同步' && n.attributes.action==='open:account-recovery-downloading'));
  for(const state of ['downloading','ready','partial','retrying','unavailable','revoked']) {
    const nodes=walk(await getScreen(`account-recovery-${state}`).component());
    assert.ok(nodes.some(n=>n.textContent?.includes('没有备份的旧密钥无法重建')));
    assert.equal(nodes.filter(n=>n.tag==='input').length,0);
    for(const title of ['已下载密文','已托管密钥','已解密记录','缺少密钥']) {
      const row=nodes.find(n=>n.attributes.title===title);assert.ok(row);
      if(state==='revoked')assert.equal(row.attributes.trailing,'—');
    }
    const retry=nodes.find(n=>n.attributes.label==='重试同步');
    assert.equal(Boolean(retry),['partial','retrying','unavailable'].includes(state));
    if(retry)assert.ok(getScreen(retry.attributes.action.slice(5)));
  }
});
