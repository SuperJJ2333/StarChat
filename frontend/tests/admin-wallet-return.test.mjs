import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminShell} from '../src/admin-dashboard.js';

class Element {
 constructor(tag){this.tag=tag;this.children=[];this.dataset={};this.handlers={};this.style={setProperty(){}};this.className='';this.hidden=false;this.open=false;this.textContent='';this.classList={add(){},remove(){},toggle(){}};}
 append(...nodes){this.children.push(...nodes);}
 prepend(node){this.children.unshift(node);}
 replaceChildren(...nodes){this.children=nodes;}
 setAttribute(name,value){this[name]=value;}
 addEventListener(name,callback){const previous=this.handlers[name];this.handlers[name]=previous?event=>{previous(event);callback(event);}:callback;}
 removeEventListener(name){delete this.handlers[name];}
 remove(){this.removed=true;}
 focus(){}
 createTHead(){const head=new Element('thead');this.append(head);return head;}
 createTBody(){const body=new Element('tbody');this.append(body);return body;}
 insertRow(){const row=new Element('tr');this.append(row);return row;}
 querySelector(selector){
  const wanted=selector.slice(1);
  return this.walk().find(node=>selector[0]==='.'?node.className?.split(' ').includes(wanted):selector[0]==='#'?node.id===wanted:node.tag===selector)??null;
 }
 walk(){return [this,...this.children.flatMap(child=>child?.walk?.()??[])];}
 click(){this.handlers.click?.();}
}
function installDocument(){
 const previous={document:globalThis.document,localStorage:globalThis.localStorage,matchMedia:globalThis.matchMedia,addEventListener:globalThis.addEventListener,removeEventListener:globalThis.removeEventListener};
 globalThis.document={createElement:tag=>new Element(tag),createElementNS:(_,tag)=>new Element(tag)};
 globalThis.localStorage={getItem:()=>null,setItem(){}};
 globalThis.matchMedia=()=>({matches:false});
 globalThis.addEventListener=()=>{};globalThis.removeEventListener=()=>{};
 return ()=>Object.assign(globalThis,previous);
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const modules=[['点钻流水','','ledger','admin.ledger.read'],['USDT提现与支付','','wallet','admin.withdrawals.read']];
function navigate(page,key){
 const target=page.walk().find(node=>node.dataset?.module===key);
 assert.ok(target,`module ${key} exists`);target.click();
}
test('wallet menu return passes a one-page read view only within the same actor and session epoch',async()=>{
 const restore=installDocument();let page,epoch=1;const rendered=[];
 try{
  page=createAdminShell({
   context:{permissions:['*'],capabilities:{wallet_owner_read:true},actor:{id:'owner',display_name:'管理员'},overview:{}},
   api:{getOverview:async()=>({}),getPointIssuance:async()=>({items:[]})},modules,
   getWalletCacheEpoch:()=>epoch,
   renderModule:(key,_,context)=>{
    rendered.push({key,context});const panel=new Element('section');
    if(key==='wallet-chain'){panel.exportReadView=()=>({offset:25,items:[{txid:'a'.repeat(64)}]});panel.dispose=()=>{};}
    return panel;
   }
  });
  await settle();navigate(page,'wallet-chain');await settle();
  assert.equal(rendered.at(-1).context.walletReadView,undefined);
  navigate(page,'ledger');await settle();navigate(page,'wallet-chain');await settle();
  assert.equal(rendered.at(-1).context.walletReadView.offset,25);
  assert.equal(rendered.at(-1).context.walletReadViewEpoch,1);
  navigate(page,'ledger');await settle();epoch=2;navigate(page,'wallet-chain');await settle();
  assert.equal(rendered.at(-1).context.walletReadView,undefined,'a new management session cannot inherit the old view');
 }finally{page?.dispose();restore();}
});

test('wallet denial clears an exported menu snapshot before another menu return',async()=>{
 const restore=installDocument();let page;const rendered=[];
 try{
  page=createAdminShell({
   context:{permissions:['*'],capabilities:{wallet_owner_read:true},actor:{id:'owner',display_name:'管理员'},overview:{}},
   api:{getOverview:async()=>({}),getPointIssuance:async()=>({items:[]})},modules,
   getWalletCacheEpoch:()=>1,
   renderModule:(key,_,context)=>{
    rendered.push({key,context});const panel=new Element('section');
    if(key==='wallet-chain'){panel.exportReadView=()=>({offset:25});panel.dispose=()=>{};}
    return panel;
   }
  });
  await settle();navigate(page,'wallet-chain');await settle();navigate(page,'ledger');await settle();
  rendered.find(row=>row.key==='wallet-chain').context.onWalletReadDenied();
  navigate(page,'wallet-chain');await settle();
  assert.equal(rendered.at(-1).context.walletReadView,undefined);
 }finally{page?.dispose();restore();}
});
