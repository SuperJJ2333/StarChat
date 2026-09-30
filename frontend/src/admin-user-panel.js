import {pageSizeControl,changePageSize} from './admin-pagination.js?v=20260930-admin-navigation';
import {formatBeijingTime, statusLabel} from './admin-formatters.js';
import {can} from './admin-api.js?v=20260930-admin-navigation';

const el=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=String(text);return node;};
const action=(label,handler,cls='admin-secondary')=>{const node=el('button',cls,label);node.type='button';node.addEventListener('click',handler);return node;};
const userName=user=>user.nickname ? `${user.nickname}（${user.username || '未设置畅聊号'}）` : user.username || '未设置用户名';
export const BAN_REASONS=[['POLICY_VIOLATION','违反平台规则'],['SPAM','垃圾广告'],['HARASSMENT','骚扰他人'],['FRAUD','诈骗风险'],['SECURITY_RISK','账号安全风险']];
export const BAN_DURATIONS=[['60','1 小时'],['1440','24 小时'],['10080','7 天'],['43200','30 天'],['','永久']];

export function userPanel(api,{module='security',context={},initialData,onReauthenticate}={}) {
  const panel=el('section','admin-card admin-user-panel');
  let pageSize=10;
  let revision=0,disposed=false,currentQuery='',cursors=[undefined],page=0,nextCursor=null,loading=false,failedRequest=null;
  const security=module==='security'&&can(context,'admin.bans.read');
  let selectUser=()=>{};
  if(security){const form=banForm(api,{onReauthenticate,onSuccess:()=>Promise.all([load(),loadBans()])});selectUser=form.selectUser;panel.append(form);}
  const heading=el('div','admin-panel-heading');heading.append(el('h2',null,module==='security'?'用户列表':'平台注册用户'));
  const search=el('form','admin-user-search');search.name='user-search';
  const input=el('input','admin-filter');input.name='q';input.type='search';input.maxLength=128;input.placeholder='搜索畅聊号、用户名或邮箱';input.setAttribute('aria-label','搜索畅聊号、用户名或邮箱');
  const find=el('button','admin-primary','搜索');find.type='submit';search.append(input,find);
  const message=el('p','admin-audit-note');message.setAttribute('role','status');
  const tableWrap=el('div','admin-user-table-wrap'),table=el('table','admin-table');
  const head=el('thead'),headRow=el('tr');
  for(const label of ['注册时间','畅聊号','用户名','邮箱验证','账号状态',...(security?['操作']:[])])headRow.append(el('th',null,label));
  head.append(headRow);const body=el('tbody');table.append(head,body);tableWrap.append(table);
  const pager=el('div','admin-user-pagination'),position=el('span');
  const previous=action('上一页',()=>{if(loading||page===0)return;load({query:currentQuery,cursors:[...cursors],page:page-1});});
  const next=action('下一页',()=>{if(loading||!nextCursor)return;load({query:currentQuery,cursors:[...cursors.slice(0,page+1),nextCursor],page:page+1});});
  const retry=action('重新加载',()=>load(failedRequest??undefined));pager.append(previous,position,next,retry,pageSizeControl(changePageSize(value=>pageSize=value,()=>load({query:currentQuery,cursors:[undefined],page:0}))));
  panel.append(heading,search,message,tableWrap,pager);
  function render(payload){
    body.replaceChildren();
    const items=Array.isArray(payload.items)?payload.items:[];
    if(!items.length){const row=el('tr'),cell=el('td',null,'暂无匹配用户');cell.colSpan=security?6:5;row.append(cell);body.append(row);}
    for(const item of items){
      const row=el('tr');
      for(const value of [formatBeijingTime(item.created_at),item.username||'—',item.nickname||'—',item.email_verified_at?`已验证 · ${formatBeijingTime(item.email_verified_at)}`:'未验证',statusLabel(item.status)])row.append(el('td',null,value));
      if(security){const cell=el('td');if(item.active_ban)cell.append(unbanButton(item.active_ban,userName(item)));else if(item.status==='SUSPENDED')cell.append(el('span','admin-audit-note','账号受限 · 请核对记录'));else cell.append(action('选择封禁',()=>selectUser(item)));row.append(cell);}
      body.append(row);
    }
    nextCursor=payload.next_cursor||null;position.textContent=`第 ${page+1} 页 · 共 ${payload.total??items.length} 位用户`;
    message.textContent=items.length?'时间均为北京时间':'未找到匹配用户，请调整搜索条件。';
  }
  function controls(){previous.disabled=loading||page===0;next.disabled=loading||!nextCursor;retry.disabled=loading;}
  async function load(target={query:currentQuery,cursors:[...cursors],page}){
    if(disposed)return false;
    const request=++revision;loading=true;controls();message.textContent='正在加载用户…';
    try{const data=await api.getModule(module,{q:target.query,limit:pageSize,cursor:target.cursors[target.page]});if(disposed||request!==revision)return false;currentQuery=target.query;cursors=[...target.cursors];page=target.page;failedRequest=null;render(data);return true;}
    catch(error){if(disposed||request!==revision)return false;failedRequest=target;message.textContent=`用户加载失败：${error.message||'请重新加载'}。保留上次筛选和页码，现有列表可能已过期。`;return false;}
    finally{if(!disposed&&request===revision){loading=false;controls();}}
  }
  search.addEventListener('submit',event=>{event.preventDefault();return load({query:input.value.trim(),page:0,cursors:[undefined]});});
  function unbanButton(ban,label){
    let commandKey;
    const button=action('解除封禁',async()=>{
      if(button.disabled||!globalThis.confirm?.(`确认解除 ${label} 的当前封禁？`))return;
      button.disabled=true;commandKey??=crypto.randomUUID();
      try{await api.command(`/api/v1/admin/security/bans/${encodeURIComponent(ban.id)}/revoke`,{reason_code:'BAN_REVOKE',expected_starts_at:ban.starts_at},{idempotencyKey:commandKey});commandKey=null;await Promise.all([load(),loadBans()]);}
      catch(error){message.textContent=`解除失败：${error.message??'请重试'}。请刷新核对当前封禁。`;button.disabled=false;}
    });return button;
  }
  let bansOffset=0,bansSize=10,bansRevision=0;
  const bans=el('section','admin-active-bans'),bansRows=el('div','admin-table-scroll'),bansState=el('p','admin-audit-note');bansState.setAttribute('role','status');
  const bansPrevious=action('上一页封禁',()=>{void loadBans(Math.max(0,bansOffset-bansSize));}),bansNext=action('下一页封禁',()=>{void loadBans(bansOffset+bansSize);});
  if(security&&api.getActiveBans){bans.append(el('h2',null,'当前封禁的用户与 IP'),bansState,bansRows,bansPrevious,bansNext,pageSizeControl(changePageSize(value=>bansSize=value,()=>loadBans(0)),{label:'封禁列表每页条数'}));panel.append(bans);void loadBans();}
  async function loadBans(targetOffset=bansOffset){
    if(!security||!api.getActiveBans||disposed)return true;const version=++bansRevision;bansPrevious.disabled=bansNext.disabled=true;
    try{const result=await api.getActiveBans({limit:bansSize,offset:targetOffset});if(disposed||version!==bansRevision)return false;
      bansOffset=targetOffset;const table=el('table','admin-table'),head=el('thead'),row=el('tr'),body=el('tbody');for(const label of ['类型','对象','封禁时间','到期时间','操作'])row.append(el('th',null,label));head.append(row);
      for(const item of result.items){const row=el('tr');for(const value of [item.target_type==='ip'?'IP':'用户',item.target,formatBeijingTime(item.starts_at),item.ends_at?formatBeijingTime(item.ends_at):'永久'])row.append(el('td',null,value));const cell=el('td');cell.append(unbanButton(item,item.target));row.append(cell);body.append(row);}table.append(head,body);bansRows.replaceChildren(table);bansState.textContent=result.total?`共 ${result.total} 条当前封禁 · 第 ${Math.floor(bansOffset/bansSize)+1} 页`:'暂无当前封禁';bansPrevious.disabled=bansOffset===0;bansNext.disabled=bansOffset+result.items.length>=result.total;return true;
    }catch(error){if(!disposed&&version===bansRevision)bansState.textContent=`封禁记录加载失败：${error.message??'请重试'}。上次数据可能已过期。`;return false;}
  }
  panel.refresh=async()=>{const result=await Promise.all([load(),loadBans()]);return result.every(Boolean);};panel.dispose=()=>{disposed=true;revision++;bansRevision++;};
  if(initialData){render(initialData);controls();}else load();
  return panel;
}

function banForm(api,{onReauthenticate,onSuccess}) {
  const form=el('form','admin-ban-form');form.name='ban-user';
  const title=el('h2',null,'封禁用户或 IP'),fields=el('div','admin-ban-fields');
  const select=(name,label,choices,value)=>{const wrap=el('label',null,label),node=el('select','admin-filter');node.name=name;for(const [key,text]of choices){const option=el('option',null,text);option.value=key;node.append(option);}node.value=value;wrap.append(node);fields.append(wrap);return node;};
  const type=select('target_type','封禁类型',[['user','用户'],['ip','IP 地址']],'user');
  const targetWrap=el('label',null,'封禁对象'),target=el('input','admin-filter');target.name='target_display';target.readOnly=true;target.placeholder='从下方用户列表选择';target.required=true;targetWrap.append(target);fields.append(targetWrap);
  const reason=select('reason_code','原因',BAN_REASONS,'POLICY_VIOLATION');
  const duration=select('duration_minutes','时长',BAN_DURATIONS,'1440');
  const submit=el('button','admin-primary','确认封禁');submit.type='submit';fields.append(submit);
  const status=el('p','admin-audit-note');status.setAttribute('role','status');
  let selected=null,busy=false,uncertain=false;
  function resetTarget(){selected=null;target.value='';target.readOnly=type.value==='user';target.placeholder=type.value==='user'?'从下方用户列表选择':'输入需要封禁的 IP 地址';}
  type.addEventListener('change',resetTarget);
  form.selectUser=user=>{if(busy||uncertain)return;selected={id:user.id,label:userName(user)};type.value='user';target.readOnly=true;target.value=selected.label;target.focus();};
  form.append(title,fields,status);
  form.addEventListener('submit',async event=>{
    event.preventDefault();if(busy||uncertain)return;
    if(type.value==='user'&&!selected?.id){status.textContent='请先从用户列表选择封禁对象。';return;}
    const value=type.value==='user'?selected.id:target.value.trim();
    if(!value){status.textContent='请填写 IP 地址。';return;}
    busy=true;submit.disabled=true;status.replaceChildren();status.textContent='正在提交封禁…';
    for(const field of [type,target,reason,duration])field.disabled=true;
    const body={target_type:type.value,target:value,reason_code:reason.value,duration_minutes:duration.value?Number(duration.value):null};
    try{
      await api.command('/api/v1/admin/security/bans',body,{idempotencyKey:crypto.randomUUID()});
      status.textContent=`已封禁：${selected?.label||value}`;resetTarget();await onSuccess();
    }catch(error){
      uncertain=error.code==='NETWORK_ERROR'||error.status===0||error.status>=500||!error.status;
      status.textContent=uncertain?'提交结果尚未确认，请刷新用户状态并核对审计记录；请勿重复提交。':error.message||'封禁未成功，已保留填写内容。';
      if(error.code==='RECENT_LOGIN_REQUIRED'&&onReauthenticate){
        const verify=action('验证身份',async()=>{verify.disabled=true;try{const ok=await onReauthenticate();status.textContent=ok?'身份已验证，请核对封禁对象后再次提交。':'尚未完成身份验证，已保留填写内容。';}finally{verify.disabled=false;}});status.append(verify);
      }
    }finally{busy=false;submit.disabled=uncertain;for(const field of [type,target,reason,duration])field.disabled=uncertain;}
  });
  return form;
}
