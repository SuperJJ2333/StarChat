import {refreshIcon} from './admin-dashboard.js';
const make=(tag,cls,text)=>{const node=document.createElement(tag);node.className=cls??'';if(text!==undefined)node.textContent=String(text);return node;};
export function supportPayoutPanel(api,{actor={},onBack}={}) {
  const panel=make('section','admin-card admin-recharge-panel'),status=make('p','admin-audit-note'),body=make('div','recharge-section');
  status.setAttribute('role','status');panel.append(make('h2',null,'客服提现订单'),status);
  let disposed=false,generation=0,items=[],filter='all',cursor=null;
  let activeOrder=null,operationFeedback=null,listFailed=false;
  const dialogs=new Set(),drafts=new Map(),orderFeedbacks=new Map();
  function feedback(text,error=false,orderId=activeOrder){if(orderId){text=`订单 ${orderId}：${text}`;orderFeedbacks.set(orderId,{text,error});}status.textContent=text;status.className=error?'admin-load-error':'admin-audit-note';if(operationFeedback&&activeOrder===orderId){operationFeedback.textContent=text;operationFeedback.className=status.className;operationFeedback.hidden=false;}}
  const labels={SUBMITTED:'等待处理',REQUESTED:'等待处理',CLAIMED:'处理中',REVIEWING:'核对中',NEEDS_REVIEW:'需核对',UNKNOWN:'出款结果待核对',SETTLED:'已完成',CANCELLED:'已取消'};
  const claims=new Map(),busy=new Set();
  const owned=item=>item.claimed_by===actor.id && claims.has(item.id) && Date.parse(item.claim_expires_at)>Date.now();
  const evidenceOwned=item=>item.claimed_by===actor.id && claims.has(item.id) && Boolean(item.execution_started_at);
  const button=(parent,label,run,disabled=false)=>{const node=make('button',label==='处理请求'?'admin-primary':'admin-secondary',label);node.disabled=disabled;node.addEventListener('click',()=>{if(!disposed&&!node.disabled)void run();});parent.append(node);return node;};
  if(onBack)button(panel,'← 充值请求',onBack);
  const filters=make('div','recharge-filter-tabs');filters.setAttribute('role','group');filters.setAttribute('aria-label','提现请求范围');const filterButtons=new Map();
  for(const [value,label] of [['all','待处理请求'],['mine','我正在处理'],['review','需核对'],['history','已完成与取消']]){const tab=button(filters,label,()=>{filter=value;for(const [key,b] of filterButtons){b.setAttribute('aria-pressed',String(key===filter));b.className='admin-secondary'+(key===filter?' active':'');}render();});filterButtons.set(value,tab);tab.setAttribute('aria-pressed',String(value===filter));if(value===filter)tab.className+=' active';}
  const header=make('header','admin-panel-heading');header.append(filters);const refresh=refreshIcon(async()=>{if(refresh.disabled)return;refresh.disabled=true;refresh.setAttribute('aria-busy','true');try{await load();}finally{refresh.disabled=false;refresh.setAttribute('aria-busy','false');}});refresh.title='刷新提现请求';refresh.setAttribute('aria-label',refresh.title);header.append(refresh);panel.append(header,body);
  const next=button(panel,'下一页提现',()=>load(false),true);
  function render(){
    for(const dialog of dialogs)dialog.close?.();dialogs.clear();operationFeedback=null;
    body.replaceChildren();
    const shown=items.filter(item=>filter==='mine'?item.claimed_by===actor.id:filter==='review'?item.processing_stage==='NEEDS_REVIEW'||item.status==='UNKNOWN':filter==='history'?['SETTLED','CANCELLED'].includes(item.status):true);
    if(!shown.length)body.append(make('p','admin-audit-note','暂无符合条件的提现订单'));
    for(const item of shown){
      const orderFeedback=(text,error=false)=>feedback(text,error,item.id);
      let card=make('section','recharge-section');body.append(card);
      card.append(make('h3',null,`提现单 ${item.id}`),make('p','admin-audit-note',`用户 ${item.user_id??'—'} · ${labels[item.processing_stage??item.status]??'状态待确认'}`),
        make('p',null,`申请 ${item.funding_amount??item.amount} ${item.funding_asset==='CAIBI'?'点钻':'USDT'} · 最终应付 ${item.final_receive??'待确认'} USDT`));
      if(item.expires_at)card.append(make('p','admin-audit-note',`截止（北京） ${new Date(item.expires_at).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}`));
      if(['SETTLED','CANCELLED'].includes(item.status)){card.append(make('p','admin-audit-note',item.settlement_txid?`核验交易 ${item.settlement_txid}`:'订单已结束'));continue;}
      const summary=card,dialog=make('dialog','admin-proof-dialog admin-order-dialog');dialog.setAttribute('aria-label','处理提现请求');dialog.hidden=true;
      dialog.dataset && (dialog.dataset.orderId=item.id);
      dialog.addEventListener('input',event=>{if(event.target?.tagName==='INPUT'){const draft=drafts.get(item.id)??{};draft[event.target.placeholder]=event.target.value;drafts.set(item.id,draft);}});
      const heading=make('header','admin-proof-heading'),close=make('button','admin-dialog-close','×');close.setAttribute('aria-label','关闭处理窗口');heading.append(make('h2',null,'处理提现请求'),close);
      card=make('div','admin-proof-body');const notice=make('p',orderFeedbacks.get(item.id)?.error?'admin-load-error':'admin-audit-note',orderFeedbacks.get(item.id)?.text??'');notice.setAttribute('aria-live','polite');
      card.append(make('p','admin-audit-note',`订单 ${item.id}`),make('h3',null,`应付 ${item.final_receive??'待确认'} USDT`),notice);dialog.append(heading,card);dialogs.add(dialog);
      let claimAction=null;
      const open=button(summary,'处理请求',()=>{activeOrder=item.id;operationFeedback=notice;summary.append(dialog);dialog.hidden=false;dialog.showModal?.();if(claimAction)void claimAction();});const cache=make('div','recharge-operation-cache');cache.append(dialog);summary.append(cache);
      close.addEventListener('click',()=>{dialog.hidden=true;dialog.close?.();cache.append(dialog);activeOrder=null;operationFeedback=null;});dialog.addEventListener('close',()=>{dialog.hidden=true;if(dialogs.has(dialog)&&activeOrder===item.id){cache.append(dialog);activeOrder=null;operationFeedback=null;open.focus?.();}});
      if(activeOrder===item.id){summary.append(dialog);operationFeedback=notice;dialog.hidden=false;dialog.showModal?.();}
      const add=(label,run)=>button(card,label,run,busy.has(item.id));
      const mutate=async(action,payload={})=>{
        const isClaim=['claim','review-claim'].includes(action);
        if(disposed||busy.has(item.id)||(!isClaim&&!(['txid','correct-candidate','reconcile'].includes(action)?evidenceOwned(item):owned(item))))return;
        busy.add(item.id);render();
        try{
          const result=await api.supportPayoutCommand(item.id,action,{...payload,...isClaim?{}:{claim_token:claims.get(item.id)}},{idempotencyKey:crypto.randomUUID()});
          if(disposed)return;
          if(result.claim_token && result.claimed_by===actor.id)claims.set(item.id,result.claim_token);
          Object.assign(item,result);
          orderFeedback(result.status==='SETTLED'?'服务端已核验出款并完成结算':'已更新服务端状态；未核验前不显示完成，勿重复付款。');
        }catch(error){claims.delete(item.id);orderFeedback(`操作未确认，已停止修改：${error.message??'处理权失效，请刷新查询'}`,true);}
        finally{busy.delete(item.id);if(!disposed)render();}
      };
      if(!owned(item)&&!evidenceOwned(item)){
        card.append(make('p','admin-audit-note',item.claimed_by&&item.claimed_by!==actor.id?'其他客服处理中（只读）':'接手后由你负责处理，系统会核对处理权和有效期。'));
        if(item.processing_stage==='NEEDS_REVIEW'){
          if(item.status==='REQUESTED'&&!item.execution_started_at&&!item.candidate_txid&&(!item.claimed_by||Date.parse(item.claim_expires_at)<=Date.now()))add('复核认领过期提现',()=>mutate('review-claim',{reason_code:'SUPPORT_PAYOUT_EXPIRED_REVIEW'}));
        }else if(!item.claimed_by || item.claimed_by===actor.id || (!item.execution_started_at&&Date.parse(item.claim_expires_at)<=Date.now())){claimAction=()=>mutate('claim');add('接手处理',claimAction);}
        continue;
      }
      if(owned(item)&&!item.execution_started_at){
        const rate=make('input','admin-filter');rate.placeholder='确认结算汇率（点钻/USDT）';rate.setAttribute('aria-label',rate.placeholder);card.append(rate);
        add('确认汇率并开始财务处理',()=>{if(!/^\d+(?:\.\d+)?$/.test(rate.value.trim())){orderFeedback('请填写结算汇率',true);return;}return mutate('adjust-rate',{new_rate:rate.value.trim(),reason_code:'SUPPORT_PAYOUT_SETTLEMENT'});});
      }
      if(!item.instructions && owned(item) && item.status!=='UNKNOWN' && item.processing_stage!=='NEEDS_REVIEW'){
        card.append(make('p','admin-audit-note','开始出款后不可由其他客服接管；先确认应付，禁止重复付款。'));
        add('确认开始出款',()=>mutate('begin-payment',{expected_digest:item.digest}));
      }else if(item.instructions){
        card.append(make('p',null,`收款地址 ${item.instructions.target_address} · 网络 ${item.instructions.network} · 应付 ${item.instructions.amount} USDT`),make('p','admin-audit-note',item.instructions.warning??'仅支付一次，未知结果必须核对，禁止重复付款。'));
      }
      if(item.execution_started_at){
        const txid=make('input','admin-filter');txid.placeholder='出款交易哈希';txid.value=item.candidate_txid??'';txid.setAttribute('aria-label',txid.placeholder);card.append(txid);
        add('提交出款交易凭证',()=>{if(!txid.value.trim()){orderFeedback('请填写出款交易哈希',true);return;}return mutate('txid',{txid:txid.value.trim()});});
        if(item.status==='UNKNOWN'&&item.candidate_txid)add('更正出款交易凭证',()=>{if(!txid.value.trim()||txid.value.trim()===item.candidate_txid){orderFeedback('请填写需核对的新交易哈希；原凭证仍保留审计。',true);return;}return mutate('correct-candidate',{txid:txid.value.trim(),reason_code:'PAYOUT_TXID_CORRECTION'});});
        add('查询链上核验结果',()=>mutate('reconcile'));
      }
    }
    for(const dialog of dialogs){const draft=drafts.get(dialog.dataset?.orderId);if(draft)for(const input of dialog.querySelectorAll?.('input')??[]){if(Object.hasOwn(draft,input.placeholder))input.value=draft[input.placeholder];}}
  }
  async function load(reset=true){
    const version=++generation;next.disabled=true;if(reset)cursor=null;
    if(!items.length)body.replaceChildren(make('p','admin-audit-note','正在加载提现请求…'));
    try{const page=await api.getSupportPayouts({...cursor?{cursor}:{},limit:50});if(disposed||version!==generation)return;
      if(listFailed){feedback('提现列表已恢复');listFailed=false;}
      items=page.items??[];cursor=page.next_cursor??null;next.disabled=!cursor;
      for(const item of items){if(item.claim_token&&item.claimed_by===actor.id)claims.set(item.id,item.claim_token);if(item.claimed_by!==actor.id||(!item.execution_started_at&&Date.parse(item.claim_expires_at)<=Date.now()))claims.delete(item.id);}
      render();
    }catch(error){if(!disposed&&version===generation){listFailed=true;claims.clear();body.replaceChildren();feedback(`提现列表加载失败：${error.message??'请重试'}`,true);}}
  }
  panel.heartbeat=async()=>{
    if(disposed||document.hidden)return;
    let lost=false;
    for(const item of items){if(!owned(item)||busy.has(item.id)||item.status==='UNKNOWN'||item.processing_stage==='NEEDS_REVIEW')continue;
      try{const result=await api.supportPayoutCommand(item.id,'heartbeat',{claim_token:claims.get(item.id)},{idempotencyKey:crypto.randomUUID()});if(!disposed)Object.assign(item,result);}
      catch{claims.delete(item.id);lost=true;feedback('续租未确认，已停止修改，请刷新查询。',true,item.id);}
    }
    if(lost&&!disposed)render();
  };
  const timer=setInterval(()=>void panel.heartbeat(),60000);timer.unref?.();
  const resume=()=>{if(!document.hidden)void load();};document.addEventListener?.('visibilitychange',resume);
  panel.refresh=()=>load();panel.refreshOrders=()=>load();
  panel.dispose=()=>{disposed=true;++generation;for(const dialog of dialogs)dialog.close?.();dialogs.clear();claims.clear();clearInterval(timer);document.removeEventListener?.('visibilitychange',resume);};
  void load();return panel;
}
