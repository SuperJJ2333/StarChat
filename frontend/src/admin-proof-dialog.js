import {formatBeijingTime,actorLabel,reasonLabel} from './admin-formatters.js';
const node=(tag,cls,text)=>{const element=document.createElement(tag);if(cls)element.className=cls;if(text!==undefined)element.textContent=text;return element;};
export function openProofDialog({id,api,formatPoints}){
  const previous=document.activeElement,dialog=node('dialog','admin-proof-dialog');dialog.setAttribute('aria-label','发行与回收凭证');
  const header=node('header','admin-proof-heading'),heading=node('div');heading.append(node('p','admin-eyebrow','账本审计'),node('h2',null,'发行与回收凭证'));
  const close=node('button','admin-dialog-close','×');close.type='button';close.setAttribute('aria-label','关闭凭证');header.append(heading,close);
  const content=node('div','admin-proof-body'),footer=node('footer','admin-proof-footer','只读凭证 · 金额与记录以业务账本为准');dialog.append(header,content,footer);
  document.body.append(dialog);
  let disposed=false;
  function destroy(){if(disposed)return;disposed=true;dialog.remove();if(previous?.isConnected)previous.focus();}
  close.addEventListener('click',()=>dialog.close());dialog.addEventListener('close',destroy);dialog.addEventListener('cancel',()=>{});
  dialog.addEventListener('click',event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)dialog.close();}});
  dialog.showModal();close.focus();
  async function load(){
    content.replaceChildren(node('p','admin-audit-note','正在读取凭证…'));content.setAttribute('aria-busy','true');
    try{
      const proof=await api.getPointIssuanceDetail(id);if(disposed)return;
      const summary=node('section','admin-proof-summary');summary.append(node('p','admin-kpi-label',reasonLabel(proof.reason_code)),node('strong','admin-proof-amount',`${formatPoints(proof.amount)} 点钻`));
      const fields=node('dl','admin-proof-fields');
      for(const [label,value] of [['交易编号',id],['记账时间（北京时间）',formatBeijingTime(proof.created_at)],['操作人（畅聊号）',actorLabel(proof)],['业务原因',reasonLabel(proof.reason_code)],...(proof.reversal_of_id?[['原交易',proof.reversal_of_id]]:[])])fields.append(node('dt',null,label),node('dd',null,value));
      const entries=node('table','admin-table');entries.createTHead().insertRow().append(...['账户','资产','记账数量'].map(t=>node('th',null,t)));
      const body=entries.createTBody();for(const entry of proof.entries??[])body.insertRow().append(node('td',null,entry.account_username??({'PLATFORM_CLEARING':'平台发行账户','PLATFORM_FEE':'平台手续费账户'}[entry.account_id]??entry.account_id)),node('td',null,entry.asset==='CAIBI'?'点钻':entry.asset),node('td','admin-numeric',formatPoints(entry.amount)));
      const scroll=node('div','admin-table-scroll');scroll.append(entries);
      const audit=node('section','admin-proof-audits');audit.append(node('h3',null,'审计记录'));
      for(const record of proof.audits??[]){const row=node('article','admin-proof-audit');row.append(node('strong',null,reasonLabel(record.reason_code)),node('p',null,`${formatBeijingTime(record.created_at)} · ${actorLabel(record)}`),node('small',null,`审计编号 ${record.id}`));audit.append(row);}
      if(!proof.audits?.length)audit.append(node('p','admin-audit-note','暂无关联审计记录'));
      content.replaceChildren(summary,fields,scroll,audit);
      if(proof.anomalies?.length)content.append(node('p','admin-load-error','凭证关联存在异常，请核对原始审计与冲正记录。'));
    }catch(error){if(disposed)return;const retry=node('button','admin-secondary','重试');retry.type='button';retry.addEventListener('click',()=>void load());content.replaceChildren(node('p','admin-load-error',`凭证读取失败：${error.message??'请重试'}`),retry);}
    finally{if(!disposed)content.setAttribute('aria-busy','false');}
  }
  void load();return ()=>{if(dialog.open)dialog.close();destroy();};
}
