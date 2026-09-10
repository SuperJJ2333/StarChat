import {formatBeijingTime, parseBeijingInput} from './admin-formatters.js';
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
const scenes={GROUP:'群聊红包',EXCLUSIVE:'专属红包',DIRECT:'单聊红包',TRANSFER:'转账',OTHER:'其他',UNKNOWN:'红包场景待核实'};
const modes={RANDOM:'手气红包',EQUAL:'普通红包',EXCLUSIVE:'专属红包',OTHER:'其他'};
export function ledgerLabels(item){
  const type=[scenes[item.scene]??'其他',!['OTHER','EXCLUSIVE'].includes(item.mode)?modes[item.mode]:null].filter(Boolean).join(' · ');
  const missing=item.anomalies?.includes('MISSING_REASON')||!item.reason_text;
  return [type,missing?'原因待补充（异常数据）':item.reason_text];
}
export function ledgerFilters(values){
  const result={...values};
  for(const key of ['start_at','end_at'])if(result[key]){
    const stamp=parseBeijingInput(result[key]);if(!Number.isFinite(stamp))throw Error('请输入有效的北京时间');result[key]=new Date(stamp).toISOString();
  }
  if(result.start_at&&result.end_at&&result.start_at>=result.end_at)throw Error('开始时间必须早于结束时间');
  return result;
}
export function ledgerPanel(api){
  const panel=node('section',undefined,'admin-card admin-ledger-panel');
  panel.append(node('h2','点钻流水'),node('p','按业务账本查询。红包场景与分配方式分别展示；原因缺失的历史记录标为异常。','admin-audit-note'));
  const form=node('form',undefined,'admin-filters'),inputs={};
  for(const [key,label] of [['username','畅聊号'],['nickname','用户名'],['email','邮箱'],['start_at','开始时间（北京时间）'],['end_at','结束时间（北京时间）']]){
    const labelNode=node('label',label),input=node('input',undefined,'admin-filter');input.name=key;input.setAttribute('aria-label',label);input.type=key.endsWith('_at')?'datetime-local':'search';input.step='1';input.maxLength=128;labelNode.append(input);form.append(labelNode);inputs[key]=input;
  }
  for(const [key,label,options] of [['scene','业务类型',scenes],['mode','红包分配方式',modes]]){
    const wrap=node('label',label),select=node('select',undefined,'admin-filter');select.setAttribute('aria-label',label);
    for(const [value,text] of [['','全部'],...Object.entries(options)]){const option=node('option',text);option.value=value;select.append(option);}inputs[key]=select;wrap.append(select);form.append(wrap);
  }
  const submit=node('button','查询','admin-primary');submit.type='submit';const reset=node('button','重置','admin-secondary');reset.type='button';form.append(submit,reset);
  const state=node('p','正在读取流水…','admin-audit-note');state.setAttribute('role','status');
  const rows=node('div',undefined,'admin-table-scroll'),paging=node('div',undefined,'admin-filters');
  const previous=node('button','上一页','admin-secondary'),next=node('button','下一页','admin-secondary');previous.type=next.type='button';paging.append(previous,next);panel.append(form,state,rows,paging);
  let active={},stack=[undefined],index=0,nextCursor,revision=0,disposed=false,busy=false;
  async function load(filters=active,page=index,cursors=stack){
    const version=++revision;busy=true;submit.disabled=reset.disabled=previous.disabled=next.disabled=true;rows.setAttribute('aria-busy','true');
    try{
      const result=await api.getLedgerEntries({...filters,limit:25,cursor:cursors[page]});if(disposed||version!==revision)return false;
      active=filters;index=page;stack=cursors;nextCursor=result.next_cursor;
      const table=node('table',undefined,'admin-table'),head=node('thead'),headers=node('tr'),body=node('tbody');
      for(const text of ['时间（北京时间）','畅聊号','用户名','类型','金额（点钻）','原因','交易编号'])headers.append(node('th',text));head.append(headers);
      for(const item of result.items){const tr=node('tr'),[type,reason]=ledgerLabels(item);for(const value of [formatBeijingTime(item.created_at),item.username??({ESCROW:'业务托管账户',PLATFORM:'平台账户',UNKNOWN:'未关联账户'}[item.account_kind]??'—'),item.nickname??'—',type,item.amount,reason,item.transaction_id])tr.append(node('td',value));if(item.anomalies?.length)tr.className='admin-data-anomaly';body.append(tr);}
      table.append(head,body);rows.replaceChildren(table);state.textContent=result.total?`共 ${result.total} 条 · 第 ${index+1} 页`:'当前筛选条件下暂无流水';return true;
    }catch(error){if(!disposed&&version===revision)state.textContent=`查询失败：${error.message}。保留上次结果，请重试。`;return false;}
    finally{if(!disposed&&version===revision){busy=false;submit.disabled=reset.disabled=false;previous.disabled=index===0;next.disabled=!nextCursor;rows.setAttribute('aria-busy','false');}}
  }
  form.addEventListener('submit',event=>{event.preventDefault();if(busy)return;try{void load(ledgerFilters(Object.fromEntries(Object.entries(inputs).map(([k,v])=>[k,v.value.trim()]))),0,[undefined]);}catch(error){state.textContent=error.message;}});
  reset.addEventListener('click',()=>{if(busy)return;for(const input of Object.values(inputs))input.value='';void load({},0,[undefined]);});
  previous.addEventListener('click',()=>{if(!busy&&index>0)void load(active,index-1,stack);});
  next.addEventListener('click',()=>{if(!busy&&nextCursor)void load(active,index+1,[...stack.slice(0,index+1),nextCursor]);});
  panel.refresh=()=>load();panel.dispose=()=>{disposed=true;++revision;};void load();return panel;
}
