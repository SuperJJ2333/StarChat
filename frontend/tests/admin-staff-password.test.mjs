import test from 'node:test';
import assert from 'node:assert/strict';
import {staffPasswordDialog} from '../src/admin-staff-password-dialog.js';

class Element {
  constructor(tag){this.tag=tag;this.children=[];this.handlers={};this.value='';}
  append(...items){this.children.push(...items);}
  setAttribute(key,value){this[key]=value;}
  addEventListener(key,handler){this.handlers[key]=handler;}
  focus(){this.focused=true;}
  showModal(){this.open=true;}
  close(){this.open=false;this.handlers.close?.();}
  remove(){this.removed=true;}
  find(tag){return [this,...this.children.flatMap(item=>item.find(tag))].filter(item=>item.tag===tag);}
}
function setup(){globalThis.document={createElement:tag=>new Element(tag),body:new Element('body')};}

test('staff password dialog validates fields and returns to login after changing shared password',async()=>{
  setup();let sent,completed=0;
  const dialog=staffPasswordDialog({session:{changeStaffPassword:async body=>{sent=body;}},onSuccess:()=>{completed++;}});
  const fields=dialog.find('input');
  fields.find(item=>item.name==='current_password').value='old-password';
  fields.find(item=>item.name==='new_password').value='new-password-123';
  fields.find(item=>item.name==='confirm_password').value='new-password-123';
  await dialog.find('form')[0].handlers.submit({preventDefault(){}});
  assert.deepEqual(sent,{current_password:'old-password',new_password:'new-password-123'});
  assert.equal(completed,1);assert.equal(dialog.removed,true);
  assert.ok(fields.every(item=>item.value===''));
});

test('password dialog rejects a mismatched confirmation without calling the API',async()=>{
  setup();let calls=0;
  const dialog=staffPasswordDialog({session:{changeStaffPassword:async()=>{calls++;}}});
  const fields=dialog.find('input');
  fields.find(item=>item.name==='current_password').value='old-password';
  fields.find(item=>item.name==='new_password').value='new-password-123';
  fields.find(item=>item.name==='confirm_password').value='different-password';
  await dialog.find('form')[0].handlers.submit({preventDefault(){}});
  assert.equal(calls,0);assert.equal(dialog.open,true);
  assert.ok(dialog.find('p').some(item=>item.textContent?.includes('一致')));
});

test('password dialog keeps new password editable on server rejection and clears old proof',async()=>{
  setup();
  const dialog=staffPasswordDialog({session:{changeStaffPassword:async()=>{throw Error('当前密码不正确');}}});
  const fields=dialog.find('input');
  fields.find(item=>item.name==='current_password').value='wrong-password';
  fields.find(item=>item.name==='new_password').value='new-password-123';
  fields.find(item=>item.name==='confirm_password').value='new-password-123';
  await dialog.find('form')[0].handlers.submit({preventDefault(){}});
  assert.equal(dialog.open,true);
  assert.equal(fields.find(item=>item.name==='current_password').value,'');
  assert.equal(fields.find(item=>item.name==='new_password').value,'new-password-123');
  assert.ok(dialog.find('p').some(item=>item.textContent?.includes('当前密码不正确')));
});
