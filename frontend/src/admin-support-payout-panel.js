const make=(tag,cls,text)=>{const node=document.createElement(tag);node.className=cls??'';if(text!==undefined)node.textContent=String(text);return node;};
export function supportPayoutPanel(api,{actor={},onBack}={}) {
  const panel=make('section','admin-card admin-recharge-panel'),status=make('p','admin-audit-note'),body=make('div','recharge-section');
  status.setAttribute('role','status');panel.append(make('h2',null,'客服提现订单'),status);
  let disposed=false,generation=0,items=[],filter='all',cursor=null;
  const claims=new Map(),busy=new Set();
  const owned=item=>item.claimed_by===actor.id && claims.has(item.id) && Date.parse(item.claim_expires_at)>Date.now();
  const evidenceOwned=item=>item.claimed_by===actor.id && claims.has(item.id) && Boolean(item.execution_started_at);
  const button=(parent,label,run,disabled=false)=>{const node=make('button','admin-secondary',label);node.disabled=disabled;node.addEventListener('click',()=>{if(!disposed&&!node.disabled)void run();});parent.append(node);return node;};
  if(onBack)button(panel,'返回充值队列',onBack);
  const filters=make('div','admin-command-form');
  for(const [value,label] of [['all','公共提现队列'],['mine','我的处理中'],['review','待核对'],['history','已完成与取消']])button(filters,label,()=>{filter=value;render();});
  panel.append(filters);button(panel,'刷新提现订单',()=>load());panel.append(body);
  const next=button(panel,'下一页提现',()=>load(false),true);
  function render(){
    body.replaceChildren();
    const shown=items.filter(item=>filter==='mine'?item.claimed_by===actor.id:filter==='review'?item.processing_stage==='NEEDS_REVIEW'||item.status==='UNKNOWN':filter==='history'?['SETTLED','CANCELLED'].includes(item.status):true);
    if(!shown.length)body.append(make('p','admin-audit-note','暂无符合条件的提现订单'));
    for(const item of shown){
      const card=make('section','recharge-section');body.append(card);
      card.append(make('h3',null,`提现单 ${item.id}`),make('p','admin-audit-note',`用户 ${item.user_id??'—'} · ${item.processing_stage??item.status}`),
        make('p',null,`申请 ${item.funding_amount??item.amount} ${item.funding_asset==='CAIBI'?'点钻':'USDT'} · 最终应付 ${item.final_receive??'待确认'} USDT`));
      if(item.expires_at)card.append(make('p','admin-audit-note',`截止（北京） ${new Date(item.expires_at).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}`));
      if(['SETTLED','CANCELLED'].includes(item.status)){card.append(make('p','admin-audit-note',item.settlement_txid?`核验交易 ${item.settlement_txid}`:'订单已结束'));continue;}
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
          status.textContent=result.status==='SETTLED'?'服务端已核验出款并完成结算':'已更新服务端状态；未核验前不显示完成，勿重复付款。';
        }catch(error){claims.delete(item.id);status.textContent=`操作未确认，已停止修改：${error.message??'认领失效，请刷新查询'}`;}
        finally{busy.delete(item.id);if(!disposed)render();}
      };
      if(!owned(item)&&!evidenceOwned(item)){
        card.append(make('p','admin-audit-note',item.claimed_by&&item.claimed_by!==actor.id?'其他客服处理中（只读）':'请先认领，服务端核对处理权与期限。'));
        if(item.processing_stage==='NEEDS_REVIEW'){
          if(item.status==='REQUESTED'&&!item.execution_started_at&&!item.candidate_txid&&(!item.claimed_by||Date.parse(item.claim_expires_at)<=Date.now()))add('复核认领过期提现',()=>mutate('review-claim',{reason_code:'SUPPORT_PAYOUT_EXPIRED_REVIEW'}));
        }else if(!item.claimed_by || item.claimed_by===actor.id || (!item.execution_started_at&&Date.parse(item.claim_expires_at)<=Date.now()))add('认领提现',()=>mutate('claim'));
        continue;
      }
      if(owned(item)&&!item.execution_started_at){
        const rate=make('input','admin-filter');rate.placeholder='确认结算汇率（点钻/USDT）';rate.setAttribute('aria-label',rate.placeholder);card.append(rate);
        add('确认汇率并开始财务处理',()=>{if(!/^\d+(?:\.\d+)?$/.test(rate.value.trim())){status.textContent='请填写结算汇率';return;}return mutate('adjust-rate',{new_rate:rate.value.trim(),reason_code:'SUPPORT_PAYOUT_SETTLEMENT'});});
      }
      if(!item.instructions && owned(item) && item.status!=='UNKNOWN' && item.processing_stage!=='NEEDS_REVIEW'){
        card.append(make('p','admin-audit-note','开始出款后不可由其他客服接管；先确认应付，禁止重复付款。'));
        add('确认开始出款',()=>mutate('begin-payment',{expected_digest:item.digest}));
      }else if(item.instructions){
        card.append(make('p',null,`收款地址 ${item.instructions.target_address} · 网络 ${item.instructions.network} · 应付 ${item.instructions.amount} USDT`),make('p','admin-audit-note',item.instructions.warning??'仅支付一次，未知结果必须核对，禁止重复付款。'));
      }
      if(item.execution_started_at){
        const txid=make('input','admin-filter');txid.placeholder='出款交易哈希';txid.value=item.candidate_txid??'';txid.setAttribute('aria-label',txid.placeholder);card.append(txid);
        add('提交出款交易凭证',()=>{if(!txid.value.trim()){status.textContent='请填写出款交易哈希';return;}return mutate('txid',{txid:txid.value.trim()});});
        if(item.status==='UNKNOWN'&&item.candidate_txid)add('更正出款交易凭证',()=>{if(!txid.value.trim()||txid.value.trim()===item.candidate_txid){status.textContent='请填写需核对的新交易哈希；原凭证仍保留审计。';return;}return mutate('correct-candidate',{txid:txid.value.trim(),reason_code:'PAYOUT_TXID_CORRECTION'});});
        add('查询链上核验结果',()=>mutate('reconcile'));
      }
    }
  }
  async function load(reset=true){
    const version=++generation;next.disabled=true;if(reset)cursor=null;
    try{const page=await api.getSupportPayouts({...cursor?{cursor}:{},limit:50});if(disposed||version!==generation)return;
      items=page.items??[];cursor=page.next_cursor??null;next.disabled=!cursor;
      for(const item of items){if(item.claim_token&&item.claimed_by===actor.id)claims.set(item.id,item.claim_token);if(item.claimed_by!==actor.id||(!item.execution_started_at&&Date.parse(item.claim_expires_at)<=Date.now()))claims.delete(item.id);}
      render();
    }catch(error){if(!disposed&&version===generation){claims.clear();body.replaceChildren();status.textContent=`提现列表加载失败：${error.message??'请重试'}`;}}
  }
  panel.heartbeat=async()=>{
    if(disposed||document.hidden)return;
    let lost=false;
    for(const item of items){if(!owned(item)||busy.has(item.id)||item.status==='UNKNOWN'||item.processing_stage==='NEEDS_REVIEW')continue;
      try{const result=await api.supportPayoutCommand(item.id,'heartbeat',{claim_token:claims.get(item.id)},{idempotencyKey:crypto.randomUUID()});if(!disposed)Object.assign(item,result);}
      catch{claims.delete(item.id);lost=true;status.textContent='续租未确认，已停止修改，请刷新查询。';}
    }
    if(lost&&!disposed)render();
  };
  const timer=setInterval(()=>void panel.heartbeat(),60000);timer.unref?.();
  const resume=()=>{if(!document.hidden)void load();};document.addEventListener?.('visibilitychange',resume);
  panel.refresh=()=>load();panel.refreshOrders=()=>load();
  panel.dispose=()=>{disposed=true;++generation;claims.clear();clearInterval(timer);document.removeEventListener?.('visibilitychange',resume);};
  void load();return panel;
}
