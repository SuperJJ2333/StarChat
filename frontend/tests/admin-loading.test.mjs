import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';

class Element {
  constructor(tag){this.tag=tag;this.children=[];}
  append(...items){this.children.push(...items);}
  setAttribute(name,value){this[name]=value;}
  find(tag){return [this,...this.children.flatMap(item=>item.find?.(tag)??[])].filter(item=>item.tag===tag);}
}

test('management loading state centers a branded icon and accessible status',async()=>{
  assert.ok(existsSync(new URL('../src/admin-loading.js',import.meta.url)),'branded management loading component exists');
  globalThis.document={createElement:tag=>new Element(tag)};
  const {adminLoadingView}=await import('../src/admin-loading.js');
  const view=adminLoadingView();
  assert.equal(view.tag,'main');assert.equal(view['role'],'status');
  assert.ok(view.className.includes('admin-loading'));
  const icon=view.find('img')[0];assert.equal(icon.src,'/assets/branding/admin-logo.png');assert.equal(icon.alt,'畅聊');
  assert.ok(view.find('span').some(item=>item.className==='admin-loading-spinner'&&item['aria-hidden']==='true'));
  assert.ok(view.find('p').some(item=>item.textContent==='正在加载管理台'));
});
