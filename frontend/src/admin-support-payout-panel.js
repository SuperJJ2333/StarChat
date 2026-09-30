import {refreshIcon} from './admin-dashboard.js';

const make=(tag,cls,text)=>{const node=document.createElement(tag);node.className=cls??'';if(text!==undefined)node.textContent=String(text);return node;};
const capabilities=['can_claim','can_takeover','can_begin','can_evidence'];
const labels={REQUESTED:'等待处理',CLAIMED:'处理中',REVIEWING:'核对中',NEEDS_REVIEW:'需核对',UNKNOWN:'出款结果待核对',SETTLED:'已完成',CANCELLED:'已取消',REJECTED:'已拒绝'};
const terminal=item=>['SETTLED','CANCELLED','REJECTED'].includes(item.status);
const rejected=item=>item.status==='REJECTED'||item.processing_stage==='REJECTED';
const payable=item=>item.execution_started_at?item.final_receive:item.prepared_receive??item.final_receive;
const has=(item,capability)=>item?.[capability]===true;
const shortHash=value=>typeof value==='string'&&value.length>=16?`${value.slice(0,8)}…${value.slice(-8)}`:'交易哈希待核对';

export function supportPayoutPanel(api,{actor={},onBack}={}) {
  const actorId=actor.id??actor.user_id;
  const panel=make('section','admin-card admin-recharge-panel admin-support-payout-panel');
  const status=make('p','admin-audit-note');status.setAttribute('role','status');
  const body=make('div','recharge-section');panel.append(make('h2',null,'客服提现订单'),status);
  let disposed=false,invalidated=false,generation=0,items=[],filter='all',cursor=null,activeOrder=null,opener=null;
  let address=null,discovery=null,confirmation=null,securityMode=null,copyFeedback='';
  const tokens=new Map(),busy=new Set(),uncertain=new Set(),drafts=new Map(),messages=new Map();
  const openers=new Map();
  const authorized=()=>!disposed&&!invalidated&&(actor.id??actor.user_id)===actorId;
  const current=()=>items.find(item=>item.id===activeOrder);
  const tokenFor=item=>tokens.get(item.id)?.evidence??tokens.get(item.id)?.claim??null;
  const button=(parent,label,run,disabled=false,cls='admin-secondary')=>{
    const node=make('button',cls,label);node.type='button';node.disabled=disabled;
    node.addEventListener('click',()=>{if(authorized()&&!node.disabled)void run(node);});parent.append(node);return node;
  };
  const notify=(item,text,error=false)=>{
    if(item)messages.set(item.id,{text,error});
    status.textContent=item?`订单 ${item.id}：${text}`:text;
    status.className=error?'admin-load-error':'admin-audit-note';
    if(activeOrder===item?.id)renderDialog();
  };
  function remember(item,result){
    if(!result||typeof result!=='object'||result.id&&result.id!==item.id)throw Error('订单状态未确认');
    const publicResult={...result},saved=tokens.get(item.id)??{};
    delete publicResult.target_address;
    if(publicResult.instructions){publicResult.instructions={...publicResult.instructions};delete publicResult.instructions.target_address;}
    if(typeof publicResult.claim_token==='string')saved.claim=publicResult.claim_token;
    if(typeof publicResult.evidence_token==='string')saved.evidence=publicResult.evidence_token;
    tokens.set(item.id,saved);delete publicResult.claim_token;delete publicResult.evidence_token;
    for(const capability of capabilities)publicResult[capability]=result[capability]===true;
    Object.assign(item,publicResult);
    if(!has(item,'can_evidence')){address=null;discovery=null;copyFeedback='';}
  }
  function scrub(){
    address=null;discovery=null;confirmation=null;securityMode=null;copyFeedback='';
    drafts.clear();tokens.clear();uncertain.clear();clearProof();dialogBody.replaceChildren();
  }
  function clearProof(){for(const input of dialogBody.querySelectorAll?.('input')??[])if(input.type==='password')input.value='';}
  function finishClose(){
    const previous=openers.get(activeOrder)??opener;activeOrder=null;opener=null;
    address=null;discovery=null;confirmation=null;securityMode=null;copyFeedback='';
    clearProof();dialogBody.replaceChildren();dialog.hidden=true;previous?.focus?.();
  }
  const dialog=make('dialog','admin-proof-dialog admin-order-dialog admin-payout-dialog');
  dialog.setAttribute('aria-label','处理提现请求');dialog.hidden=true;
  const heading=make('header','admin-proof-heading');heading.append(make('h2',null,'处理提现请求'));
  const close=button(heading,'×',()=>dialog.close?.(),false,'admin-dialog-close');close.setAttribute('aria-label','关闭处理窗口');
  const dialogBody=make('div','admin-proof-body');dialog.append(heading,dialogBody);dialog.addEventListener('close',finishClose);
  if(onBack)button(panel,'← 充值请求',onBack);
  const filters=make('div','recharge-filter-tabs');filters.setAttribute('role','group');filters.setAttribute('aria-label','提现请求范围');
  const filterButtons=new Map();
  for(const [value,label] of [['all','待处理请求'],['mine','我正在处理'],['review','需核对'],['history','已完成与取消']])filterButtons.set(value,button(filters,label,()=>{filter=value;updateTabs();renderList();}));
  function updateTabs(){for(const [value,tab] of filterButtons){tab.setAttribute('aria-pressed',String(value===filter));tab.className='admin-secondary'+(value===filter?' active':'');}}
  updateTabs();
  const header=make('header','admin-panel-heading');header.append(filters);
  const refresh=refreshIcon(async()=>{if(refresh.disabled)return;refresh.disabled=true;refresh.setAttribute('aria-busy','true');try{await load();}finally{refresh.disabled=false;refresh.setAttribute('aria-busy','false');}});
  refresh.title='刷新提现请求';refresh.setAttribute('aria-label',refresh.title);header.append(refresh);
  panel.append(header,body);const next=button(panel,'下一页提现',()=>load(false),true);panel.append(dialog);

  function renderList(){
    body.replaceChildren();openers.clear();
    const shown=items.filter(item=>filter==='mine'?item.claimed_by===actorId||item.evidence_actor_id===actorId:filter==='review'?item.processing_stage==='NEEDS_REVIEW'||item.status==='UNKNOWN':filter==='history'?terminal(item):true);
    if(!shown.length)body.append(make('p','admin-audit-note','暂无符合条件的提现订单'));
    for(const item of shown){
      const card=make('section','recharge-section admin-payout-order');body.append(card);
      card.append(make('h3',null,`提现单 ${item.id}`),make('p','admin-audit-note',`用户 ${item.user_id??'—'} · ${labels[item.processing_stage??item.status]??'状态待确认'}`),
        make('p',null,`申请 ${item.funding_amount??item.amount??'—'} ${item.funding_asset==='CAIBI'?'点钻':'USDT'} · 应付 ${payable(item)??'待确认'} USDT`));
      if(item.expires_at)card.append(make('p','admin-audit-note',`截止（北京） ${new Date(item.expires_at).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}`));
      if(terminal(item)){card.append(make('p','admin-audit-note',rejected(item)?'订单已拒绝':item.status==='CANCELLED'?'订单已取消':'订单已完成'));continue;}
      const permitted=has(item,'can_claim')||has(item,'can_begin')||has(item,'can_evidence');
      const viewOnly=!permitted&&has(item,'can_takeover');
      const occupied=Boolean(item.claimed_by&&item.claimed_by!==actorId)||Boolean(item.execution_started_at);
      const label=permitted?'处理请求':viewOnly?'查看订单':occupied?'正被其他客服处理中':'暂无处理权限';
      openers.set(item.id,button(card,label,node=>openOrder(item,node),!permitted&&!viewOnly,permitted?'admin-primary':'admin-secondary'));
    }
    if(activeOrder)renderDialog();
  }
  async function detail(item){
    if(typeof api.getSupportPayout!=='function')return;
    try{const result=await api.getSupportPayout(item.id);if(!authorized()||current()!==item)return;
      remember(item,result);renderList();if(item.execution_started_at&&has(item,'can_evidence'))await readAddress(item);
    }catch(error){if(authorized()&&current()===item){revoke(item);renderList();notify(item,`详情读取失败：${error.message??'请刷新'}`,true);}}
  }
  function revoke(item){tokens.delete(item.id);drafts.delete(item.id);address=null;discovery=null;confirmation=null;securityMode=null;copyFeedback='';for(const cap of capabilities)item[cap]=false;}
  async function requestProof(item,kind){confirmation=kind;securityMode=null;renderDialog();
    try{const state=await api.getWalletOperationSecurity();if(authorized()&&current()===item&&confirmation===kind){securityMode=state?.auth_mode;renderDialog();}}
    catch(error){if(authorized()&&activeOrder===item.id)notify(item,`操作验证方式读取失败：${error.message??'请重试'}`,true);}
  }
  function freshProof(){
    if(!['operation_password','totp'].includes(securityMode)){dialogBody.append(make('p','admin-load-error','正在核对当前验证方式…'));return null;}
    return input(securityMode==='operation_password'?'操作密码':'当前六位验证码','','password');
  }
  async function openOrder(item,openButton){
    if(!authorized())return;
    activeOrder=item.id;opener=openButton;address=null;discovery=null;confirmation=null;securityMode=null;copyFeedback='';
    dialog.hidden=false;renderDialog();if(!dialog.open)dialog.showModal?.();
    if(has(item,'can_claim'))await execute(item,'claim',key=>api.supportPayoutCommand(item.id,item.processing_stage==='NEEDS_REVIEW'?'review-claim':'claim',item.processing_stage==='NEEDS_REVIEW'?{reason_code:'SUPPORT_PAYOUT_EXPIRED_REVIEW'}:{},{idempotencyKey:key}));
    else await detail(item);
  }
  async function execute(item,action,call){
    if(!authorized()||!items.includes(item)||busy.has(item.id)||uncertain.has(item.id))return;
    busy.add(item.id);renderDialog();
    try{const result=await call(crypto.randomUUID());if(!authorized()||!items.includes(item))return;
      remember(item,result);renderList();notify(item,result.status==='SETTLED'?'服务端已核验出款并完成结算':'已更新服务端状态；未核验前勿重复付款。');
      if(action==='begin-payment'&&item.execution_started_at&&has(item,'can_evidence'))await readAddress(item);
    }catch(error){if(!authorized())return;
      if(error?.code==='NETWORK_ERROR'||error?.status===0)uncertain.add(item.id);
      if(error?.status===401||error?.status===403||error?.status===409){
        tokens.delete(item.id);address=null;discovery=null;drafts.delete(item.id);
        for(const capability of capabilities)item[capability]=false;
      }
      notify(item,`操作未确认：${error?.message??'请刷新服务器状态'}。请核对订单，勿重复付款。`,true);
      if(uncertain.has(item.id))await load();
    }finally{busy.delete(item.id);if(authorized())renderDialog();}
  }
  function action(item,label,run,disabled=false){return button(dialogBody,label,run,disabled||busy.has(item.id)||uncertain.has(item.id));}
  function input(placeholder,value='',type='text'){const node=make('input','admin-filter');node.placeholder=placeholder;node.setAttribute('aria-label',placeholder);node.value=value;node.type=type;node.autocomplete='off';dialogBody.append(node);return node;}
  function reasonSelect(options){const select=make('select','admin-filter');select.setAttribute('aria-label','拒绝或接管原因');for(const [value,label] of options){const choice=make('option',null,label);choice.value=value;select.append(choice);}select.value=options[0][0];dialogBody.append(select);return select;}
  function beginBody(item){
    const receive=item.funding_asset==='CAIBI'?item.prepared_receive:item.final_receive;
    if(!item.target_address_masked||!receive)return null;
    const body={claim_token:tokenFor(item),expected_digest:item.digest};
    if(item.funding_asset==='CAIBI'){
      if(!Number.isSafeInteger(item.prepared_version)||item.prepared_version<1||typeof item.prepared_digest!=='string')return null;
      body.expected_preparation_version=item.prepared_version;body.expected_digest=item.prepared_digest;
    }
    return body.claim_token&&body.expected_digest?body:null;
  }
  function renderBeforeBegin(item){
    dialogBody.append(make('p','admin-audit-note','开始出款前，用户仍可取消；客服可拒绝。保存汇率不会开始出款或改变冻结。'));
    if(item.prepared_rate)dialogBody.append(make('p','admin-payout-preparation',`待执行汇率 ${item.prepared_rate} · 待执行应付 ${item.prepared_receive??'待确认'} USDT · 版本 ${item.prepared_version}`));
    if(item.funding_asset==='CAIBI'){
      const rate=input('确认结算汇率（点钻/USDT）',drafts.get(item.id)?.rate??item.prepared_rate??'');
      action(item,'保存结算汇率',()=>{const value=rate.value.trim();drafts.set(item.id,{rate:value});
        if(!/^\d+(?:\.\d{1,6})?$/.test(value)||!Number.isSafeInteger(item.prepared_version)){notify(item,'请填写有效汇率并刷新准备版本',true);return;}
        void execute(item,'adjust-rate',key=>api.supportPayoutCommand(item.id,'adjust-rate',{claim_token:tokenFor(item),new_rate:value,reason_code:'SUPPORT_PAYOUT_SETTLEMENT',expected_preparation_version:item.prepared_version},{idempotencyKey:key}));},!tokenFor(item));
    }
    action(item,'拒绝提现',()=>{if(item.owner_proof_required)void requestProof(item,'reject');else{confirmation='reject';renderDialog();}},!tokenFor(item));
    const terms=beginBody(item);
    action(item,'确认开始出款',()=>{confirmation='begin';renderDialog();},!terms);
    if(confirmation==='begin'){
      dialogBody.append(make('p','admin-payout-confirm',`请核对脱敏收款地址 ${item.target_address_masked??'待服务端提供'} · 网络 TRON · 应付 ${item.prepared_receive??item.final_receive??'待确认'} USDT。开始后不可取消，请勿重复付款。`));
      action(item,'确认且开始出款',()=>{confirmation=null;void execute(item,'begin-payment',key=>api.supportPayoutCommand(item.id,'begin-payment',terms,{idempotencyKey:key}));});
      action(item,'返回修改汇率',()=>{confirmation=null;renderDialog();});
    }
    if(confirmation==='reject'){
      const reasons=reasonSelect([['PAYOUT_ADDRESS_INVALID','收款地址无效'],['PAYOUT_DETAILS_MISMATCH','订单资料不符'],['PAYOUT_POLICY_INELIGIBLE','不符合受理规则']]);
      dialogBody.append(make('p','admin-audit-note','拒绝会释放原冻结并记录实际操作人，请再次确认。'));
      const proof=item.owner_proof_required?freshProof():null;
      if(item.owner_proof_required&&!proof)return;
      const confirm=action(item,'确认拒绝提现',()=>{const body={claim_token:tokenFor(item),reason_code:reasons.value};
        if(item.owner_proof_required){if(!proof.value.trim())return;body.proof={[securityMode==='operation_password'?'operation_password':'mfa_proof']:proof.value};proof.value='';}
        confirmation=null;securityMode=null;void execute(item,'reject',key=>api.rejectSupportPayout(item.id,body,{idempotencyKey:key}));},Boolean(proof));
      proof?.addEventListener('input',()=>{confirm.disabled=!proof.value.trim()||busy.has(item.id)||uncertain.has(item.id);});
    }
  }
  async function readAddress(item){
    if(!authorized()||activeOrder!==item.id||!item.execution_started_at||!has(item,'can_evidence'))return;
    try{const result=await api.readSupportPayoutAddress(item.id,{claim_token:tokenFor(item)},{idempotencyKey:crypto.randomUUID()});
      if(!authorized()||current()!==item||!has(item,'can_evidence'))return;
      if(typeof result?.target_address!=='string'||!result.target_address)throw Error('地址响应无效');
      address={target_address:result.target_address,network:result.network};renderDialog();
    }catch(error){
      address=null;
      if(error?.status===401||error?.status===403||error?.status===409){tokens.delete(item.id);item.can_evidence=false;discovery=null;drafts.delete(item.id);}
      if(authorized()&&activeOrder===item.id)notify(item,`完整地址读取失败：${error?.message??'请重新授权'}`,true);
    }
  }
  async function copyAddress(item){
    if(!authorized()||activeOrder!==item.id||!has(item,'can_evidence')||!address)return;
    try{await globalThis.navigator.clipboard.writeText(address.target_address);copyFeedback='完整收款地址已复制';}
    catch{copyFeedback='复制失败，请检查剪贴板权限';}
    if(authorized()&&activeOrder===item.id)renderDialog();
  }
  async function findCandidates(item){
    if(!authorized()||!has(item,'can_evidence'))return;
    discovery={status:'LOADING',candidates:[]};renderDialog();
    try{const result=await api.discoverSupportPayout(item.id,tokenFor(item));
      if(!authorized()||current()!==item||!has(item,'can_evidence'))return;
      discovery={status:result?.status,candidates:Array.isArray(result?.candidates)?result.candidates:[]};renderDialog();
    }catch(error){if(authorized()&&activeOrder===item.id){discovery={status:'ERROR',candidates:[]};notify(item,`链上发现失败：${error?.message??'请手动输入哈希'}`,true);}}
  }
  function renderDiscovery(item){
    if(!discovery)return;
    const {status:state,candidates}=discovery;
    const message=state==='LOADING'?'正在查找链上出款…':state==='EMPTY'?'未找到候选；这不代表未付款，可手动输入交易哈希。':state==='INCOMPLETE'?'历史扫描未完成，不能排除已付款；请手动输入交易哈希。':state==='UNAVAILABLE'?'链上服务不可用，请稍后重试或手动输入交易哈希。':state==='COMPLETE'?(candidates.length===1?'发现 1 笔候选，请对照 imToken 记录主动选择。':`发现 ${candidates.length} 笔候选，请逐笔对照 imToken 记录。`):'链上结果待人工核对，请手动输入交易哈希。';
    dialogBody.append(make('p','admin-payout-discovery-status',message));
    if(state!=='COMPLETE')return;
    for(const candidate of candidates){
      const row=make('div','admin-payout-candidate');dialogBody.append(row);
      const timestamp=Number.isSafeInteger(candidate.timestamp_ms)?new Date(candidate.timestamp_ms).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'}):'时间待核对';
      row.append(make('p',null,`${shortHash(candidate.txid)} · ${candidate.amount??'金额待核对'} USDT · ${candidate.masked_target_address??'地址已脱敏'} · ${timestamp} · ${candidate.evidence_status??'证据待核对'}`));
      const conflicting=['CONFLICT','AMBIGUOUS','STALE','UNAVAILABLE'].includes(candidate.evidence_status);
      if(conflicting)row.append(make('p','admin-load-error','归属或证据存在冲突，须人工调查。'));
      else button(row,'选择此交易',()=>void execute(item,'select-discovered',key=>api.selectSupportPayoutCandidate(item.id,{claim_token:tokenFor(item),txid:candidate.txid},{idempotencyKey:key})));
    }
  }
  function renderEvidence(item){
    if(address){
      const box=make('section','admin-payout-address');box.append(make('h3',null,'客户收款地址'),make('p','admin-payout-address-value',address.target_address),make('p','admin-audit-note',`网络 ${address.network??'TRON'} · 仅按不可变付款指令支付一次。`));dialogBody.append(box);
      button(box,'复制收款地址',()=>copyAddress(item));const copyStatus=make('p','admin-audit-note',copyFeedback);copyStatus.setAttribute('role','status');box.append(copyStatus);
    }else action(item,'读取收款地址',()=>readAddress(item));
    const txid=input('出款交易哈希',drafts.get(item.id)?.txid??item.candidate_txid??'');
    action(item,'提交出款交易凭证',()=>{const value=txid.value.trim();drafts.set(item.id,{...drafts.get(item.id),txid:value});
      if(!value){notify(item,'请填写出款交易哈希',true);return;}
      void execute(item,'txid',key=>api.supportPayoutCommand(item.id,'txid',{claim_token:tokenFor(item),txid:value},{idempotencyKey:key}));});
    if(item.candidate_txid)action(item,'更正出款交易凭证',()=>{const value=txid.value.trim();if(!value||value===item.candidate_txid){notify(item,'请填写需核对的新交易哈希',true);return;}
      void execute(item,'correct-candidate',key=>api.supportPayoutCommand(item.id,'correct-candidate',{claim_token:tokenFor(item),txid:value,reason_code:'PAYOUT_TXID_CORRECTION'},{idempotencyKey:key}));});
    action(item,'查找链上出款',()=>findCandidates(item));renderDiscovery(item);
    if(item.candidate_txid)action(item,'核验已选交易',()=>void execute(item,'reconcile',key=>api.supportPayoutCommand(item.id,'reconcile',{claim_token:tokenFor(item)},{idempotencyKey:key})));
  }
  function renderTakeover(item){
    action(item,'申请接管',()=>requestProof(item,'takeover'));
    if(confirmation!=='takeover')return;
    dialogBody.append(make('p','admin-payout-confirm','接管须另行确认原因及本次钱包操作证明；已开始订单只能移交证据核对权。'));
    if(!['operation_password','totp'].includes(securityMode)){dialogBody.append(make('p','admin-load-error','正在核对当前验证方式…'));return;}
    const reason=reasonSelect([[item.execution_started_at?'SUPPORT_PAYOUT_EVIDENCE_TAKEOVER':'SUPPORT_PAYOUT_OWNER_TAKEOVER',item.execution_started_at?'接管链上证据核对':'接管未开始出款订单']]);
    const proof=input(securityMode==='operation_password'?'操作密码':'当前六位验证码','','password');
    action(item,'确认接管',()=>{if(!Number.isSafeInteger(item.version)||!proof.value){notify(item,'订单版本或当次证明缺失，请刷新',true);return;}
      const credential=proof.value;proof.value='';confirmation=null;const field=securityMode==='operation_password'?'operation_password':'mfa_proof';securityMode=null;
      void execute(item,'takeover',key=>api.takeoverSupportPayout(item.id,{expected_claim_version:item.version,reason_code:reason.value,proof:{[field]:credential}},{idempotencyKey:key}));});
  }
  function renderDialog(){
    if(!activeOrder)return;
    const item=current();clearProof();dialogBody.replaceChildren();
    if(!item){dialogBody.append(make('p','admin-load-error','订单已不在当前列表，请返回后刷新。'));return;}
    const message=messages.get(item.id);dialogBody.append(make('p','admin-audit-note',`订单 ${item.id}`),make('h3',null,`应付 ${payable(item)??'待确认'} USDT`));
    if(message){const notice=make('p',message.error?'admin-load-error':'admin-audit-note',message.text);notice.setAttribute('role','status');dialogBody.append(notice);}
    if(item.target_address_masked)dialogBody.append(make('p','admin-audit-note',`收款地址 ${item.target_address_masked}`));
    action(item,'返回提现列表',()=>dialog.close?.());
    if(terminal(item)){dialogBody.append(make('p','admin-audit-note','订单已终止'));return;}
    if(has(item,'can_takeover')&&!has(item,'can_begin')&&!has(item,'can_evidence')){renderTakeover(item);return;}
    if(has(item,'can_begin')&&!item.execution_started_at)renderBeforeBegin(item);
    if(has(item,'can_evidence')&&item.execution_started_at)renderEvidence(item);
    if(!has(item,'can_begin')&&!has(item,'can_evidence'))dialogBody.append(make('p','admin-audit-note','当前仅可查看，处理资格请以服务端状态为准。'));
  }
  async function load(reset=true){
    const version=++generation;next.disabled=true;if(reset)cursor=null;address=null;discovery=null;copyFeedback='';
    if(!items.length)body.replaceChildren(make('p','admin-audit-note','正在加载提现请求…'));
    try{const page=await api.getSupportPayouts({...cursor?{cursor}:{},limit:50});if(!authorized()||version!==generation)return;
      items=(page.items??[]).map(raw=>{const item={...raw},saved=tokens.get(item.id)??{};
        delete item.target_address;if(item.instructions){item.instructions={...item.instructions};delete item.instructions.target_address;}
        if(typeof item.claim_token==='string')saved.claim=item.claim_token;if(typeof item.evidence_token==='string')saved.evidence=item.evidence_token;
        if(saved.claim||saved.evidence)tokens.set(item.id,saved);delete item.claim_token;delete item.evidence_token;
        for(const capability of capabilities)item[capability]=raw[capability]===true;
        if(!has(item,'can_begin')&&!has(item,'can_evidence'))tokens.delete(item.id);return item;});
      cursor=page.next_cursor??null;next.disabled=!cursor;
      const active=current();if(active&&!has(active,'can_evidence')){address=null;discovery=null;drafts.delete(active.id);}renderList();
    }catch(error){if(authorized()&&version===generation){scrub();items=[];openers.clear();body.replaceChildren();renderDialog();notify(null,`提现列表加载失败：${error?.message??'请重试'}`,true);}}
  }
  panel.heartbeat=async()=>{if(!authorized()||document.hidden)return;
    for(const item of items){if(!has(item,'can_begin')||item.execution_started_at||!tokenFor(item)||busy.has(item.id))continue;
      try{const result=await api.supportPayoutCommand(item.id,'heartbeat',{claim_token:tokenFor(item)},{idempotencyKey:crypto.randomUUID()});if(authorized())remember(item,result);}
      catch{tokens.delete(item.id);item.can_begin=false;address=null;drafts.delete(item.id);notify(item,'续租未确认，已停止修改，请刷新查询。',true);}}
    if(authorized())renderList();};
  const timer=setInterval(()=>void panel.heartbeat(),60000);timer.unref?.();
  const resume=()=>{if(!document.hidden)void load();};document.addEventListener?.('visibilitychange',resume);
  const identityInvalidated=()=>{invalidated=true;++generation;scrub();dialog.close?.();};globalThis.addEventListener?.('admin-session-expired',identityInvalidated);
  panel.refresh=()=>load();panel.refreshOrders=()=>load();
  panel.dispose=()=>{disposed=true;++generation;scrub();dialog.close?.();clearInterval(timer);document.removeEventListener?.('visibilitychange',resume);globalThis.removeEventListener?.('admin-session-expired',identityInvalidated);};
  void load();return panel;
}
