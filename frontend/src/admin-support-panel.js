const el=(tag,text,cls)=>{const n=document.createElement(tag);n.className=cls??'';if(text!==undefined)n.textContent=text;return n;};
const key=()=>globalThis.crypto?.randomUUID?.()??`support-${Date.now()}-${Math.random()}`;
// 派发金额必须是大于 0、最多两位小数的数字；不合规直接本地拦截，不打接口。
const GRANT_AMOUNT_PATTERN=/^\d{1,12}(\.\d{1,2})?$/;
const setFeedback=(node,kind,message)=>{node.className=`admin-audit-note admin-support-feedback is-${kind}`;node.textContent=message;node.replaceChildren(el('span',undefined,'admin-feedback-icon'),el('span',message));node.role=kind==='error'?'alert':'status';};

export function supportPanel(api,{mode='both'}={}){
  const panel=el('section',undefined,'admin-card admin-support-panel');
  let disposed=false,revision=0,offset=0,total=0,grantTarget,grantSelect,manage;
  const grantKeys=new Map();
  const supportField=(labelText,control)=>{
    const field=el('div',undefined,'admin-support-field');
    const label=Object.assign(el('label',labelText),{htmlFor:control.id});
    field.append(label,control);
    return field;
  };
  const supportForm=(title,fields,submit,feedback)=>{
    const form=el('form',undefined,'admin-command-form admin-support-command');
    const heading=el('div',undefined,'admin-support-heading');
    const actions=el('div',undefined,'admin-support-actions');
    heading.append(el('h2',title));actions.append(submit);
    feedback.className='admin-audit-note admin-support-feedback';
    form.append(heading,...fields,actions,feedback);
    return form;
  };
  const state=el('p','正在读取客服…','admin-audit-note');
  const search=el('input',undefined,'admin-filter');search.id='support-search';search.type='search';search.placeholder='搜索畅聊号、昵称或邮箱';search.maxLength=320;
  const list=el('div',undefined,'admin-table-scroll');
  const previous=el('button','上一页','admin-secondary'),next=el('button','下一页','admin-secondary');
  previous.type=next.type='button';
  async function load(){
    const current=++revision;
    try{
      const data=await api.getSupportAgents({query:search.value,limit:25,offset,dispatch_eligible:mode==='grant'?true:undefined});
      if(disposed||current!==revision)return false;total=data.total??0;render(data.items??[]);return true;
    }catch(error){if(!disposed&&current===revision)state.textContent=`读取失败：${error.message??'请重试'}。保留当前草稿。`;return false;}
  }
  function render(items){
    if(grantSelect){grantSelect.replaceChildren();const none=el('option','选择已注册客服（可继续手填）');none.value='';grantSelect.append(none);for(const a of items){if(!a.dispatch_eligible)continue;const o=el('option',`${a.username} · ${a.nickname??'—'} · ${a.masked_email??'—'}`);o.value=a.id;grantSelect.append(o);}}
    const table=el('table',undefined,'admin-table'),head=el('thead'),hr=el('tr'),body=el('tbody');for(const h of ['畅聊号','昵称','邮箱','角色','后缀','操作'])hr.append(el('th',h));head.append(hr);
    for(const a of items){const tr=el('tr');for(const v of [a.username,a.nickname,a.masked_email,(a.roles??[]).join('、'),a.badge])tr.append(el('td',v??'—'));const actions=el('td');
      if(mode!=='grant'){
        const edit=el('button','编辑','admin-secondary');edit.type='button';
        edit.addEventListener('click',()=>{manage.target.value=a.id;manage.role.value=a.roles?.[0]??'SUPPORT_AGENT';manage.badge.value=a.badge??'官方客服';});
        const remove=el('button','移除客服身份','admin-secondary');remove.type='button';
        remove.addEventListener('click',async()=>{
          if(remove.disabled||!globalThis.confirm?.(`确认移除 ${a.username} 的全部客服身份？`))return;
          remove.disabled=true;
          try{await api.command(`/api/v1/admin/support-roles/${encodeURIComponent(a.id)}`,{},{method:'DELETE',idempotencyKey:key()});await load();}
          catch(error){state.textContent=`移除失败：${error.message??'请重试'}。保留当前列表。`;remove.disabled=false;}
        });
        actions.append(edit,remove);
      }
      if(mode!=='manage'&&a.dispatch_eligible){const choose=el('button','选择客服','admin-secondary');choose.type='button';choose.addEventListener('click',()=>{if(!grantTarget.disabled)grantTarget.value=a.id;});actions.append(choose);}tr.append(actions);body.append(tr);}
    table.append(head,body);list.replaceChildren(table);state.textContent=total?'':'暂无符合条件的客服';
    previous.disabled=offset===0;next.disabled=offset+25>=total;
  }
  search.addEventListener('input',()=>{offset=0;void load();});
  previous.addEventListener('click',()=>{if(offset){offset-=25;void load();}});
  next.addEventListener('click',()=>{if(offset+25<total){offset+=25;void load();}});
  if(mode!=='grant'){
    const target=el('input',undefined,'admin-filter'),role=el('select',undefined,'admin-filter'),badge=el('input',undefined,'admin-filter'),submit=el('button','保存客服','admin-primary'),feedback=el('p','');
    target.id='support-target';target.maxLength=320;target.required=true;role.id='support-role';badge.id='support-badge';badge.value='官方客服';badge.maxLength=6;for(const r of ['SUPPORT_AGENT','FINANCE_SUPPORT','SUPPORT_SUPERVISOR']){const o=el('option',r);o.value=r;role.append(o);}role.value='SUPPORT_AGENT';manage={target,role,badge};submit.type='submit';
    const form=supportForm('客服管理',[
      supportField('目标（内部 ID、畅聊号或邮箱）',target),
      supportField('客服角色',role),
      supportField('客服后缀（2–6个汉字）',badge)
    ],submit,feedback);
    form.addEventListener('submit',async e=>{
      e.preventDefault();if(submit.disabled)return;
      if(!/^[\u4e00-\u9fff]{2,6}$/.test(badge.value)){setFeedback(feedback,'error','客服后缀须为2–6个汉字');return;}
      submit.disabled=true;
      try{await api.command(`/api/v1/admin/support-roles/${encodeURIComponent(target.value)}`,{role_code:role.value,badge:badge.value},{idempotencyKey:key()});setFeedback(feedback,'success','已保存');await load();}
      catch(error){setFeedback(feedback,'error',`保存失败：${error.message??'请重试'}`);}
      finally{submit.disabled=false;}
    });panel.append(form);
  }
  if(mode!=='manage'){
    const target=el('input',undefined,'admin-filter'),select=el('select',undefined,'admin-filter'),amount=el('input',undefined,'admin-filter'),reason=el('select',undefined,'admin-filter'),submit=el('button','发放点钻','admin-primary'),feedback=el('p','');
    grantTarget=target;grantSelect=select;target.id='grant-target';select.id='grant-select';amount.id='grant-amount';reason.id='grant-reason';target.maxLength=320;target.required=true;amount.type='text';amount.inputMode='decimal';amount.placeholder='例如 88.00';amount.required=true;const r=el('option','SUPPORT_CAIBI_GRANT');r.value='SUPPORT_CAIBI_GRANT';reason.append(r);reason.value=r.value;select.addEventListener('change',()=>{if(select.value)target.value=select.value;});submit.type='submit';
    const form=supportForm('客服点钻派发',[
      supportField('选择已注册客服',select),
      supportField('派发目标',target),
      supportField('金额（点钻）',amount),
      supportField('原因代码',reason)
    ],submit,feedback);
    form.addEventListener('submit',async e=>{e.preventDefault();if(submit.disabled)return;const amountText=amount.value.trim();if(!GRANT_AMOUNT_PATTERN.test(amountText)||Number(amountText)<=0){setFeedback(feedback,'error','金额格式无效：请输入大于 0 的数字，最多两位小数（例如 88.00）');return;}const body={user_id:target.value.trim(),amount:amountText,reason_code:reason.value};const fingerprint=JSON.stringify(body);const commandKey=grantKeys.get(fingerprint)??key();grantKeys.set(fingerprint,commandKey);submit.disabled=target.disabled=select.disabled=amount.disabled=reason.disabled=true;try{const result=await api.command('/api/v1/admin/finance/adjustments',body,{idempotencyKey:commandKey});setFeedback(feedback,'success',`已发放：${result.amount} 点钻`);grantKeys.delete(fingerprint);target.value='';amount.value='';}catch(error){setFeedback(feedback,'error',`发放失败：${error.message??'请重试'}`);}finally{submit.disabled=target.disabled=select.disabled=amount.disabled=reason.disabled=false;}});panel.append(form);
  }
  panel.append(el('h2',mode==='grant'?'可派发客服':'客服列表'),Object.assign(el('label','搜索客服'),{htmlFor:search.id}),search,state,list,previous,next);panel.refresh=load;panel.dispose=()=>{disposed=true;++revision;};void load();return panel;
}
