import test from 'node:test';
import assert from 'node:assert/strict';
import { getScreen } from '../src/catalog/screens.js';

class Node {
  constructor(tag) {
    this.tag=tag;
    this.children=[];
    this.dataset={};
    this.attributes={};
    this.handlers={};
    this.classList={add:name=>{this.className=[this.className,name].filter(Boolean).join(' ');}};
  }
  append(...children) { this.children.push(...children); }
  setAttribute(name,value) { this.attributes[name]=value; }
  addEventListener(name,handler) { this.handlers[name]=handler; }
}
const walk=node=>[node,...node.children.flatMap(walk)];

test('username login and email registration dismiss keyboard on background tap', async () => {
  globalThis.HTMLElement=class {};
  let blurs=0;
  globalThis.document={
    createElement:tag=>new Node(tag),
    createElementNS:(_namespace,tag)=>new Node(tag),
    activeElement:{blur(){blurs+=1;}}
  };
  for(const id of ['auth-login-default','auth-registration-default']) {
    const root=await getScreen(id).component();
    const page=walk(root).find(node=>node.className?.split(' ').includes('p-auth'));
    assert.equal(typeof page.handlers.pointerdown,'function');
    page.handlers.pointerdown({target:{closest:()=>null}});
    page.handlers.pointerdown({target:{closest:()=>({tagName:'INPUT'})}});
  }
  assert.equal(blurs,2);
});
