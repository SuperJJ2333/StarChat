import {detailDialog} from './admin-detail-dialog.js';
import {formatBeijingTime} from './admin-formatters.js';
const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=String(text);if(cls)e.className=cls;return e;};
const reasons={EXPIRED_INTENT_REVIEW:'充值订单过期复核',PAYMENT_BEFORE_ORDER:'先付款后建单（人工证明）',ATTRIBUTION_CORRECTION:'用户归属复核',CLOCK_ORDERING_REVIEW:'时间顺序复核',OTHER:'其他（必须说明）'};
const blockers={CLOCK_UNTRUSTED:'服务器时间未通过独立校验',TEMPORAL_EVIDENCE_REQUIRED:'付款早于建单，缺少合格的人工证明或超出允许范围',ADDRESS_NETWORK_MISMATCH:'地址或链类型不匹配',FUNDS_CONTROL_BLOCKED:'资金操作已暂停',RESERVE_UNAVAILABLE:'当前资金核验证据不可用',USER_UNAVAILABLE:'用户状态不可用',ORDER_CLOSED_BY_REBIND:'订单因地址重绑关闭',PRE_ACTIVATION_BASELINE:'交易早于业务基线',REPAIR_TARGET_NOT_FOUND:'修复对象不存在',ATTRIBUTION_AMBIGUOUS:'归属存在歧义',EVENT_ALREADY_ALLOCATED:'该链上事件已分配',FUTURE_ORDER_RECORD:'订单时间晚于当前可信时间'};
export const repairBlocker=code=>blockers[code]??`校验未通过（${code}），请核对后重试`;
export function walletRepairDialog(api,item,{actorId,storage=globalThis.localStorage,onClose=()=>{}}={}){
  const inflow=item.direction==='INFLOW',kind=inflow?'deposit-repairs':'payout-reconciliations',title=inflow?'充值补入账':'提现核对';
  const content=node('section'),status=node('p','读取当前状态…','admin-audit-note'),body=node('div');content.append(status,body);
  let disposed=false,revision=0,receiptId,selected,preview,submitted=false,retryOperation;
  const modal=detailDialog(title,content,{onClose:()=>{disposed=true;++revision;onClose();}});
  const journalKey=`chatflow.manual.repair:${encodeURIComponent(actorId??'')}:${kind}:${item.txid}:${item.log_index}`;
  const button=(label,fn)=>{const b=node('button',label,'admin-secondary');b.type='button';b.addEventListener('click',fn);return b;};
  function fields(target,value){
    const dl=node('dl',undefined,'admin-proof-fields');
    for(const [key,label] of [['intent_id','充值订单号'],['order_id','提现订单号'],['username','畅聊号'],['nickname','用户名'],['user_id','用户编号'],['amount','链上金额'],['expected_amount','订单金额'],['asset','币种'],['network','链类型'],['official_address','官方地址'],['source_address','付款地址'],['target_address','目标地址'],['log_index','日志索引'],['order_status','提现订单状态'],['binding_id','地址绑定编号'],['binding_version','绑定版本'],['effective_from_block','绑定生效区块'],['effective_to_block','绑定失效区块'],['expires_at','订单有效期'],['intent_status','充值订单状态'],['status','处理状态'],['payout_status','提现核对状态'],['review_reason','核对结果说明'],['receipt_status','收款状态'],['txid','交易哈希'],['block_time','链上时间'],['created_at','订单创建时间'],['payment_before_order_seconds','付款早于建单（秒）']])if(value[key]!==undefined&&value[key]!==null)dl.append(node('dt',label),node('dd',key.endsWith('_at')||key==='block_time'?formatBeijingTime(value[key]):value[key]));target.append(dl);
  }
  async function lookup(operation){
    status.textContent='只查询请求结果，不重新提交…';try{const result=await api.getWalletRepair(kind,operation);if(disposed)return;status.textContent=`当前结果：${result.status??'已查询'}；请核对账本或提现订单的最终状态。`;body.replaceChildren();fields(body,result);if(result.status==='EXECUTED')storage.removeItem(journalKey);}catch(error){if(!disposed)status.textContent=`结果暂未确认：${error.message}。保留请求编号 ${operation}，请稍后再次查询。`;if(!disposed&&error.status===404){retryOperation=operation;body.append(button('重新预检（保留原请求编号）',()=>void start()));}}
  }
  function confirm(value){
    preview=value;body.replaceChildren();fields(body,value.confirmation??{});
    if(value.blockers?.length){status.textContent=value.blockers.map(repairBlocker).join('；');body.append(button('返回修改',()=>void start()));return;}
    status.textContent=`预检通过，有效至 ${formatBeijingTime(value.expires_at)}。提交时服务器会再次核验，操作不会自动重放。`;
    const label=node('label'),check=node('input');check.type='checkbox';label.append(check,node('span',inflow?'我已核对用户、订单、地址与金额，确认补入账':'我已核对提现订单和链上交易，确认提交核对（最终结算以系统对账为准）'));
    const execute=button('确认提交',async()=>{
      if(!check.checked||submitted||disposed)return;
      let operation;
      try{if(!actorId||!storage)throw Error('无法按账号保存请求状态');operation=retryOperation??crypto.randomUUID();storage.setItem(journalKey,JSON.stringify({operation_id:operation}));}catch(error){status.textContent=`无法保存请求恢复记录：${error.message}，未提交。`;return;}
      submitted=true;execute.disabled=true;status.textContent='正在提交，请勿重复操作…';
      try{const result=await api.executeWalletRepair(kind,{preview_id:preview.preview_id,digest:preview.digest,expected_version:preview.expected_version,operation_id:operation,confirmed:true},{idempotencyKey:operation});if(disposed)return;status.textContent=`提交结果：${result.status??'已接收'}。请刷新当前操作状态核对最终结果。`;body.replaceChildren();fields(body,result);if(result.status==='EXECUTED')storage.removeItem(journalKey);}
      catch(error){if(!disposed)status.textContent=`结果未确认：${error.message}。请求按当前账号保留，请查询结果；系统不会自动重放。`;}
      if(!disposed)body.append(button('刷新当前操作状态',()=>void lookup(operation)));
    });execute.disabled=true;check.addEventListener('change',()=>{execute.disabled=!check.checked||submitted;});body.append(label,execute,button('返回修改',()=>{if(!submitted)void start();}));
  }
  function form(){
    const form=node('form',undefined,'admin-command-form');
    const order=node('input',undefined,'admin-filter');order.required=true;order.maxLength=36;order.value=selected?.intent_id??'';order.placeholder=inflow?'充值订单号':'提现订单号';order.setAttribute('aria-label',order.placeholder);
    const reason=node('select',undefined,'admin-filter');for(const [value,label] of Object.entries(reasons)){const option=node('option',label);option.value=value;reason.append(option);}
    const detail=node('textarea',undefined,'admin-filter');detail.required=true;detail.maxLength=500;detail.placeholder='说明人工核对依据、异常原因及处理目的';detail.setAttribute('aria-label','操作原因与核对依据');
    const attestation=node('input');attestation.type='checkbox';const attestLabel=node('label');attestLabel.append(attestation,node('span','我已取得付款属于该充值订单的明确证明（先付款后建单时必须确认）'));
    const submit=node('button','预检并核对','admin-primary');submit.type='submit';form.append(order);if(inflow)form.append(reason,attestLabel);form.append(detail,submit);body.append(form);
    form.addEventListener('submit',async event=>{event.preventDefault();if(submit.disabled)return;submit.disabled=true;const version=++revision;status.textContent='正在核对实时证据…';try{const value=await api.previewWalletRepair(kind,inflow?{receipt_id:receiptId,intent_id:order.value.trim(),reason_code:reason.value,reason_detail:detail.value.trim(),payment_attestation:attestation.checked}:{order_id:order.value.trim(),txid:item.txid,log_index:item.log_index,reason_detail:detail.value.trim()});if(!disposed&&version===revision)confirm(value);}catch(error){if(!disposed&&version===revision)status.textContent=`预检未通过：${error.message}`;}finally{submit.disabled=false;}});
  }
  async function start(query=''){
    if(disposed)return;preview=null;submitted=false;body.replaceChildren();status.textContent='读取当前链上证据与候选订单…';
    if(!inflow){status.textContent='输入需要核对的提现订单号，预检会展示订单和链上证据。';form();return;}
    const version=++revision;
    try{const result=await api.getDepositRepairCandidates({txid:item.txid,log_index:String(item.log_index),query});if(disposed||version!==revision)return;receiptId=result.receipt_id;
      const search=node('input',undefined,'admin-filter');search.placeholder='订单号、畅聊号、用户名或金额';search.value=query;search.setAttribute('aria-label','搜索未处理充值订单');body.append(search,button('搜索',()=>void start(search.value.trim())));
      const table=node('table',undefined,'admin-table'),head=node('tr');for(const value of ['订单号','畅聊号 / 用户名','金额 / 币种','链类型','状态','操作'])head.append(node('th',value));const thead=node('thead'),tbody=node('tbody');thead.append(head);
      for(const candidate of result.items??[]){const row=node('tr');for(const value of [candidate.intent_id,`${candidate.username??'—'} / ${candidate.nickname??'—'}`,`${candidate.expected_amount} USDT`,candidate.network,candidate.intent_status])row.append(node('td',value));const cell=node('td');cell.append(button('选择',()=>{selected=candidate;body.replaceChildren();fields(body,candidate);form();}));row.append(cell);tbody.append(row);}table.append(thead,tbody);const scroll=node('div',undefined,'admin-table-scroll');scroll.append(table);body.append(scroll);
      status.textContent=result.items?.length?'选择订单后填写原因并预检。历史异常记录保留原始事实。':'暂无候选订单，请核查付款地址绑定与原始订单。';if(result.has_more)status.textContent+=' 候选超过100条，请输入查询条件缩小范围。';
    }catch(error){if(!disposed&&version===revision){status.textContent=`读取失败：${error.message}`;body.append(button('重试',()=>void start(query)));}}
  }
  try{const pending=JSON.parse(storage?.getItem(journalKey)??'null');if(pending?.operation_id){status.textContent='存在未确认请求，须先查询结果。不会自动重放。';body.append(button('刷新当前操作状态',()=>void lookup(pending.operation_id)));}else void start();}catch(error){status.textContent='无法读取按账号保存的请求状态，资金操作已关闭。';}
  return modal;
}
