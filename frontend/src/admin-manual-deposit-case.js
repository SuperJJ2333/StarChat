import {detailDialog} from './admin-detail-dialog.js';
import {formatBeijingTime} from './admin-formatters.js';

const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=String(text);if(cls)e.className=cls;return e;};
const blocker=code=>({ORDINARY_INTENT_AVAILABLE:'存在可用普通充值订单，请使用普通补入账流程。',HISTORICAL_BINDING_UNAVAILABLE:'链上区块对应的历史地址绑定不可用或存在歧义。',USER_MISMATCH:'系统归属用户与提交记录不一致。',RECEIPT_ALREADY_CREDITED:'该收据已入账，不能再次处理。',EVIDENCE_CONFLICT:'链上证据与已记录收据事实不一致。',EVIDENCE_EXPIRED:'链上证据已过期，请重新核对。',CLOCK_UNTRUSTED:'服务器时间校验未通过。',RESERVE_UNAVAILABLE:'资金储备证据不可用。',FUNDS_CONTROL_BLOCKED:'资金操作当前受控制策略阻止。',MANUAL_CASE_NOT_APPROVED:'补录单尚未获批准。'}[code]??`校验未通过（${code}）。`);
const caseFields=[['receipt_id','收据编号'],['txid','交易哈希'],['log_index','日志索引'],['amount','链上金额'],['asset','币种'],['network','网络'],['contract','合约'],['source_address','付款地址'],['official_address','官方地址'],['official_config_version','官方配置版本'],['block_number','区块高度'],['block_time','链上时间'],['receipt_status','收据状态'],['receipt_reason_code','收据原因'],['user_id','系统归属用户编号'],['username','系统归属畅聊号'],['nickname','系统归属昵称'],['binding_id','历史绑定编号'],['binding_version','历史绑定版本'],['effective_from_block','绑定生效区块'],['effective_to_block','绑定失效区块'],['case_id','人工补录单编号'],['status','补录单状态'],['ledger_transaction_id','最终账本交易编号'],['created_at','创建时间']];

export function manualDepositCaseDialog(api,item,{actorId,storage=globalThis.localStorage,onClose=()=>{},onCompleted=()=>{}}={}){
  const content=node('section',undefined,'admin-manual-case'),status=node('p','正在读取链上收据与系统归属…','admin-audit-note'),body=node('div');content.append(status,body);
  let context,caseView,preview,disposed=false,submitted=false,retryOperation,revision=0;
  const journalKey=`chatflow.manual.deposit-case:${encodeURIComponent(actorId??'')}:${item.txid}:${item.log_index}`;
  const modal=detailDialog('超时/无匹配订单：人工补录',content,{onClose:()=>{disposed=true;onClose();}});
  const button=(label,fn,primary=false)=>{const b=node('button',label,primary?'admin-primary':'admin-secondary');b.type='button';b.addEventListener('click',fn);return b;};
  const fields=(target,value)=>{const dl=node('dl',undefined,'admin-proof-fields');for(const [key,label] of caseFields)if(value?.[key]!==undefined&&value[key]!==null)dl.append(node('dt',label),node('dd',key.endsWith('_at')||key==='block_time'?formatBeijingTime(value[key]):value[key]));target.append(dl);};
  const evidence=value=>{const detail=node('details'),summary=node('summary','展开查看完整链上收据与补录详情');detail.append(summary);fields(detail,value);body.append(detail);};
  const disabledConfirm=reason=>{const confirm=button('确认入账',()=>{});confirm.disabled=true;confirm.title=reason;body.append(confirm,node('p',reason,'admin-audit-note'));};
  const actionSummary=value=>body.append(node('p',[value?.username&&`畅聊号：${value.username}`,value?.nickname&&`用户：${value.nickname}`,value?.user_id&&`用户编号：${value.user_id}`,value?.amount&&`金额：${value.amount} ${value.asset??''}`,value?.case_id&&`补录单：${value.case_id}`,value?.ledger_transaction_id&&`账本交易：${value.ledger_transaction_id}`].filter(Boolean).join('；'),'admin-audit-note'));
  const rationale=value=>{if(value?.reason_detail)body.append(node('p',`创建依据：${value.reason_detail}`,'admin-audit-note'));if(value?.decision)body.append(node('p',`${value.decision.decision==='APPROVED'?'批准':'驳回'}依据：${value.decision.reason_detail??'—'}；执行人：${value.decision.actor_id??'—'}；时间：${formatBeijingTime(value.decision.created_at)}`,'admin-audit-note'));};
  const storageReady=()=>Boolean(storage&&typeof storage.getItem==='function'&&typeof storage.setItem==='function'&&typeof storage.removeItem==='function');
  const save=value=>{try{if(!storageReady())return false;storage.setItem(journalKey,JSON.stringify(value));return true;}catch{return false;}};
  const clear=()=>{try{if(storageReady())storage.removeItem(journalKey);}catch{}};
  function complete(result){if(result.status!=='EXECUTED')return;clear();retryOperation=undefined;Promise.resolve().then(()=>onCompleted(result)).then(refreshed=>{if(!disposed&&refreshed===false)status.textContent='已入账；列表刷新失败，请手动刷新。';}).catch(()=>{if(!disposed)status.textContent='已入账；列表刷新失败，请手动刷新。';});}
  async function queryOperation(operation){
    const version=++revision;
    status.textContent='只查询原操作结果，不会重新提交…';
    try{const result=await api.getManualDepositCaseOperation(operation);if(disposed||version!==revision)return;body.replaceChildren();fields(body,result);status.textContent=result.status==='EXECUTED'?'已入账，正在刷新链上列表。':`当前操作状态：${result.status??'已查询'}。`;complete(result);}
    catch(error){if(disposed||version!==revision)return;status.textContent=`结果暂未确认：${error.message}。已保留原操作编号，系统不会自动重发。`;if(error.status===404){retryOperation=operation;body.append(button('重新预检（保留原操作编号）',async()=>{try{if(!caseView){const saved=JSON.parse(storage.getItem(journalKey)??'null');if(saved?.case_id)caseView=await api.getManualDepositCase(saved.case_id);}if(caseView?.status==='EXECUTED'){renderCase();return;}void previewCase();}catch(recoveryError){if(!disposed)status.textContent=`恢复补录单失败：${recoveryError.message}`;}}));}}
  }
  function executePreview(value){
    preview=value;body.replaceChildren();
    const confirmed={...context,...caseView,...(value.confirmation??{})};actionSummary(confirmed);rationale(caseView);if(value.status!=='VALIDATED'||value.blockers?.length){const reason=(value.blockers??['预检未通过']).map(blocker).join('；');status.textContent=reason;disabledConfirm(reason);body.append(button('重新预检',()=>void previewCase()));evidence(confirmed);return;}
    status.textContent=`预检通过但尚未入账。请在 ${formatBeijingTime(value.expires_at)} 前完成二次确认；提交时服务端会再次核验。`;
    const check=node('input');check.type='checkbox';const label=node('label');label.append(check,node('span','我已核对系统归属、链上收据与补录决定，确认入账。'));
    const execute=button('确认入账',async()=>{if(!check.checked||submitted||disposed)return;const operation=retryOperation??crypto.randomUUID();if(!save({case_id:caseView.case_id,operation_id:operation})){status.textContent='无法保存按账号的操作恢复记录，未提交。';return;}submitted=true;execute.disabled=true;status.textContent='正在提交，请勿重复操作…';try{const result=await api.executeManualDepositCase(caseView.case_id,{preview_id:preview.preview_id,digest:preview.digest,expected_version:preview.expected_version,operation_id:operation,confirmed:true},{idempotencyKey:operation});if(disposed)return;body.replaceChildren();fields(body,result);status.textContent=result.status==='EXECUTED'?'已入账，正在刷新链上列表。':`提交结果：${result.status??'已接收'}。请查询原操作。`;complete(result);}catch(error){if(!disposed)status.textContent=`结果未确认：${error.message}。已保留原操作编号，请只查询结果。`;}finally{if(!disposed)body.append(button('刷新当前操作状态',()=>void queryOperation(operation)));}} ,true);
    execute.disabled=true;check.addEventListener('change',()=>{execute.disabled=!check.checked||submitted;});body.append(label,execute);evidence(confirmed);
  }
  async function previewCase(){
    if(!caseView||caseView.status!=='APPROVED')return;
    const version=++revision;
    submitted=false;status.textContent='正在预检实时证据；预检不会入账…';
    try{const value=await api.previewManualDepositCase(caseView.case_id);if(!disposed&&version===revision)executePreview(value);}catch(error){if(!disposed&&version===revision)status.textContent=`预检未通过：${error.message}`;}
  }
  function decide(){
    const form=node('form',undefined,'admin-command-form'),detail=node('textarea',undefined,'admin-filter'),confirmed=node('input');detail.required=true;detail.maxLength=500;detail.placeholder='填写批准或驳回的核对依据';detail.setAttribute('aria-label','决定依据');confirmed.type='checkbox';const label=node('label');label.append(confirmed,node('span','我确认该决定基于已展示的系统归属和链上收据。'));
    let busy=false;const key=crypto.randomUUID();let approve,reject;
    const submit=decision=>async()=>{if(busy||!confirmed.checked||!detail.value.trim())return;if(!save({case_id:caseView.case_id,decision_key:key})){status.textContent='无法保存按账号的决定恢复记录，未提交。';return;}const version=++revision;busy=true;approve.disabled=reject.disabled=true;status.textContent='正在记录决定，请勿重复操作…';try{caseView=await api.decideManualDepositCase(caseView.case_id,{decision,reason_detail:detail.value.trim(),confirmed:true},{idempotencyKey:key});if(!disposed&&version===revision)renderCase();}catch(error){if(!disposed&&version===revision){status.textContent=`决定结果未确认：${error.message}。请只查询补录单后再操作。`;body.append(button('查询补录单',()=>void queryCase(caseView.case_id)));}}};
    approve=button('批准补录单',submit('APPROVED'),true);reject=button('驳回补录单',submit('REJECTED'));form.append(detail,label,approve,reject);body.append(form);
  }
  function renderCase(){
    body.replaceChildren();
    const view={...context,...caseView};actionSummary(view);rationale(caseView);
    if(caseView.status==='EXECUTED'){status.textContent='该补录单已入账；账本交易编号已显示。';evidence(view);return;}
    if(caseView.status==='APPROVED'){status.textContent='补录单已批准，但尚未入账。请进行 90 秒预检。';body.append(button('预检（不入账）',()=>void previewCase(),true));disabledConfirm('请先完成预检；预检不会入账。');evidence(view);return;}
    if(caseView.status==='REJECTED'){status.textContent='补录单已驳回，未入账。可创建新的补录单，历史记录保留。';body.append(button('创建新的补录单',()=>{clear();caseView=undefined;void load(true);}));evidence(view);return;}
    status.textContent='补录单等待明确批准或驳回；尚未入账。';decide();evidence(view);
  }
  async function queryCase(caseId){
    const selected=++revision;
    try{const value=await api.getManualDepositCase(caseId);if(disposed||selected!==revision)return;caseView=value;renderCase();}
    catch(error){if(disposed||selected!==revision)return;status.textContent=`读取补录单失败：${error.message}`;body.append(button('再次查询补录单',()=>void queryCase(caseId)));}
  }
  function create(){
    const form=node('form',undefined,'admin-command-form'),detail=node('textarea',undefined,'admin-filter'),attest=node('input');detail.required=true;detail.maxLength=500;detail.placeholder='填写链上收据、历史绑定与未入账核对依据';detail.setAttribute('aria-label','人工补录依据');attest.type='checkbox';const label=node('label');label.append(attest,node('span','我确认以上系统显示的唯一历史归属用户，不自行指定用户。'));
    const submit=node('button','创建补录单（不入账）','admin-primary');submit.type='submit';form.append(detail,label,submit);body.append(form);
    form.addEventListener('submit',async event=>{event.preventDefault();if(!attest.checked||!detail.value.trim()||submit.disabled)return;const payload={receipt_id:context.receipt_id,user_id:context.user_id,reason_detail:detail.value.trim(),ownership_attestation:true},createKey=crypto.randomUUID();if(!save({stage:'create',create_key:createKey,payload})){status.textContent='无法保存按账号的创建恢复记录，未提交。';return;}submit.disabled=true;status.textContent='正在创建补录单，尚未入账…';try{caseView=await api.createManualDepositCase(payload,{idempotencyKey:createKey});if(!save({case_id:caseView.case_id})){status.textContent='补录单已创建，请保持当前页面并查询收据恢复。';return;}if(!disposed)renderCase();}catch(error){if(!disposed)status.textContent=`创建结果未确认：${error.message}。请刷新收据状态，不会自动重发。`;}});
  }
  async function load(newCase=false){
    const version=++revision;let saved;try{if(!storageReady())throw Error('无法保存恢复记录');saved=JSON.parse(storage.getItem(journalKey)??'null');}catch(error){status.textContent=`恢复记录不可用：${error.message}。写操作已关闭。`;return;}
    if(!actorId||!storageReady()){status.textContent='无法按负责人账号保存恢复记录，写操作已关闭。';return;}
    if(saved?.operation_id){await queryOperation(saved.operation_id);return;}
    if(saved?.case_id&&!newCase){await queryCase(saved.case_id);return;}
    status.textContent='正在读取链上收据与系统归属…';body.replaceChildren();
    try{context=await api.getManualDepositCaseContext({txid:item.txid,log_index:String(item.log_index)});if(disposed||version!==revision)return;fields(body,context);if(context.blockers?.length||context.ordinary_intent_available){status.textContent=(context.blockers??[]).concat(context.ordinary_intent_available?['ORDINARY_INTENT_AVAILABLE']:[]).map(blocker).join('；');return;}if(newCase){status.textContent='已重新读取收据与归属，可创建新补录单。';create();return;}let retryBusy=false,retryButton;const retryCreate=async()=>{if(retryBusy||disposed)return;const selected=++revision;retryBusy=true;if(retryButton)retryButton.disabled=true;status.textContent='正在使用原创建请求键查询结果，请勿重复操作…';try{const value=await api.createManualDepositCase(saved.payload,{idempotencyKey:saved.create_key});if(disposed||selected!==revision)return;caseView=value;if(!save({case_id:caseView.case_id}))throw Error('无法保存补录单编号');renderCase();}catch(error){if(!disposed&&selected===revision){status.textContent=`创建结果仍未确认：${error.message}。`;retryBusy=false;if(retryButton)retryButton.disabled=false;}}};if(saved?.stage==='create'){status.textContent='创建结果未确认。可显式使用原请求键重试，系统不会自动重发。';retryButton=button('查询并重试原创建请求',()=>void retryCreate());body.append(retryButton);}if(context.cases?.length){status.textContent='已找到该收据的历史补录单，请选择继续查看。';for(const row of context.cases)body.append(button(`${row.case_id}（${row.status}）`,()=>void queryCase(row.case_id)));if(!saved?.stage)body.append(button('创建新的补录单',()=>create()));return;}if(saved?.stage==='create')return;status.textContent='已展示系统唯一历史归属。创建补录单不会入账。';create();}catch(error){if(!disposed&&version===revision){status.textContent=`读取失败：${error.message}`;body.append(button('重试',()=>void load()));}}
  }
  void load();return modal;
}
