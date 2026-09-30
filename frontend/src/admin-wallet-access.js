// The server owns authorization. This clock only hides stale private UI earlier.
const failure=code=>Object.assign(Error('钱包验证状态已变化，请重新验证并查询当前状态。'),{code,status:403});
const WALLET_READ_METHODS=new Set([
  'getSupportPayouts','getSupportPayout','getFxRate',
  'getDepositRepairCandidates','getManualDepositCaseContext','getManualDepositCase','getManualDepositCaseOperation',
  'getWalletRepair','getOwnerTransfer','getManualWalletDiagnostics','getWalletIncidents','getWalletIncident',
  'getWalletMonitorStatus','getManualWalletControl','getWalletHandover','getManualPayouts','getManualPayout',
  'getChainSummary','getChainTransactions','getChainTransaction','getWalletOperationSecurity','getWalletMfaStatus'
]);
const CREDENTIAL_METHODS=new Set(['setWalletOperationPassword','enrollWalletMfa','enableWalletMfa','abortWalletMfaEnrollment']);
export function createWalletAccess({api,actorId,getActorId=()=>actorId,now=()=>performance.now(),setTimer=setTimeout,clearTimer=clearTimeout,onChange=()=>{}}) {
  let current={kind:'unknown'},deadline=0,timer,disposed=false,generation=0,writeEpoch=0,readEpoch=0;
  function change(kind,extra={}) {
    clearTimer(timer);
    if(kind!=='ready'&&kind!=='legacy')writeEpoch++;
    if(['unknown','login','forbidden','network'].includes(kind))readEpoch++;
    if(['login','forbidden','network'].includes(kind))generation++;
    current={...current,...extra,kind};onChange(current);
  }
  function allowed(){
    if(disposed)return false;
    if(getActorId()!==actorId){change('login');return false;}
    if(current.kind==='legacy')return true;
    if(current.kind==='ready'&&now()>=deadline)change('verify');
    return current.kind==='ready';
  }
  function readAllowed(){
    if(disposed)return false;
    if(getActorId()!==actorId){change('login');return false;}
    return ['ready','legacy','verify','setup'].includes(current.kind);
  }
  function arm(){timer=setTimer(()=>{if(allowed())arm();},Math.max(1,deadline-now()));}
  function accept(value,started){
    if(value?.enabled===false){change('legacy',{enabled:false});return;}
    if(value?.enabled!==true||!['operation_password','totp'].includes(value.auth_mode)||typeof value.configured!=='boolean'||typeof value.verified!=='boolean')throw failure('INVALID_ACCESS_STATUS');
    if(!value.verified){change(value.configured?'verify':'setup',value);return;}
    const remaining=Date.parse(value.expires_at)-Date.parse(value.server_time);
    if(!Number.isFinite(remaining)||remaining>3600000)throw failure('INVALID_ACCESS_STATUS');
    // Subtract the entire request duration, conservatively accounting for transit.
    deadline=started+remaining;
    change(deadline>now()?'ready':'verify',value);if(current.kind==='ready')arm();
  }
  function reject(error,{verificationAttempt=false}={}){
    ++generation;
    if(error?.status===401||['AUTH_REQUIRED','ACCESS_TOKEN_INVALID','ADMIN_SESSION_CHANGED','UNAUTHORIZED'].includes(error?.code))change('login');
    else if(error?.code==='WALLET_ACCESS_REQUIRED'&&verificationAttempt)change('verify');
    else if(error?.status===403&&!['OPERATION_PASSWORD_INVALID','OPERATION_PASSWORD_NOT_CONFIGURED','MFA_INVALID','MFA_REPLAYED','TOTP_INVALID','TOTP_REPLAYED','INVALID_ACCESS_STATUS'].includes(error?.code))change('forbidden');
    else if(verificationAttempt&&['OPERATION_PASSWORD_INVALID','MFA_INVALID','MFA_REPLAYED','TOTP_INVALID','TOTP_REPLAYED'].includes(error?.code))change('verify',{error:error?.message??'凭据无效，请重新验证。'});
    else change('network',{error:'暂时无法确认验证状态，请重试。'});
  }
  async function update(call,{verificationAttempt=false}={}){const revision=++generation,started=now();try{const value=await call();if(disposed||revision!==generation)return false;if(getActorId()!==actorId){change('login');return false;}accept(value,started);return allowed();}catch(error){if(!disposed&&revision===generation)reject(error,{verificationAttempt});return false;}}
  return {
    state:()=>current,allowed,readAllowed,
    check:()=>update(()=>api.getWalletAccess()),
    verify:proof=>update(()=>api.verifyWalletAccess(proof),{verificationAttempt:true}),
    lock(){if(!disposed){++generation;change('unknown');}},
    async read(call){if(!readAllowed())throw failure('WALLET_ACCESS_REQUIRED');const version=readEpoch;try{const value=await call();if(!readAllowed()||version!==readEpoch)throw failure('WALLET_ACCESS_REQUIRED');return value;}catch(error){if(!disposed&&version===readEpoch){if(error?.code==='WALLET_ACCESS_REQUIRED')change('forbidden');else if(['NETWORK_ERROR','AUTH_REQUIRED','ACCESS_TOKEN_INVALID','ADMIN_SESSION_CHANGED','UNAUTHORIZED','PERMISSION_DENIED'].includes(error?.code)||[401,403].includes(error?.status))reject(error);else change('network',{error:'暂时无法确认钱包资料，请检查网络后重试。'});}throw error;}},
    async guard(call,{credentialChange=false}={}){if(!allowed())throw failure('WALLET_ACCESS_REQUIRED');const version=writeEpoch;try{const value=await call();if(!allowed()||version!==writeEpoch)throw failure('WALLET_ACCESS_REQUIRED');return value;}catch(error){if(!disposed&&current.kind!=='legacy'&&version===writeEpoch&&!(credentialChange&&error?.code==='RECENT_LOGIN_REQUIRED')&&(['WALLET_ACCESS_REQUIRED','AUTH_REQUIRED','ACCESS_TOKEN_INVALID','UNAUTHORIZED'].includes(error?.code)||[401,403].includes(error?.status)))reject(error,{verificationAttempt:true});throw error;}},
    dispose(){disposed=true;++generation;++writeEpoch;++readEpoch;clearTimer(timer);}
  };
}

export function walletAccessPanel(api,{actor,renderContent,renderSetup,onExit,onLogin,onWalletReadDenied,expectedCacheEpoch,getCacheEpoch,title:panelTitle="USDT提现与支付",scope="wallet"}={}) {
  const make=(tag,text)=>{const el=document.createElement(tag);if(text!==undefined)el.textContent=text;return el;};
  const root=make('section');root.className='admin-wallet-access';
  const content=make('div'),pending=make('p','正在确认钱包验证状态…');
  pending.setAttribute('role','status');pending.hidden=true;root.append(content,pending);
  let child,dialog,disposed=false,sessionChanged=false,background,previousOverflow,poll,setup,dialogKind,writeRequested=false,lastReadKind=null;
  let pendingRecheck=null,pollPending=false,pollToken=0,suspended=false;
  const channel=typeof BroadcastChannel==='function'?new BroadcastChannel(`chatflow-${scope}-access`):null;
  function clearContent(){child?.dispose?.();child=null;content.replaceChildren();}
  function close(){setup?.dispose?.();setup=null;dialogKind=null;if(dialog){dialog.close();dialog.remove();dialog=null;}if(background){background.inert=false;background.classList.remove('wallet-access-obscured');background=null;}if(previousOverflow!==undefined){document.body.style.overflow=previousOverflow;previousOverflow=undefined;}}
  const exit=()=>{close();onExit?.();};
  const sameSession=()=>expectedCacheEpoch===undefined||expectedCacheEpoch!==null&&getCacheEpoch?.()===expectedCacheEpoch;
  function invalidateSession(){
    if(disposed||sessionChanged)return;
    sessionChanged=true;gate.lock();clearContent();content.hidden=true;content.inert=false;content.style.visibility='';
    close();onWalletReadDenied?.();onLogin?.();
  }
  function show(state){
    if(disposed)return;
    if(['ready','legacy','verify','setup'].includes(state.kind)){
      if(!sameSession()){invalidateSession();return;}
      if(lastReadKind!==null&&(lastReadKind==='legacy')!==(state.kind==='legacy'))clearContent();
      lastReadKind=state.kind;pending.hidden=true;content.hidden=false;content.inert=false;content.style.visibility='';
      if(!child){child=renderContent(guarded,accessController);content.append(child);}
      if(suspended){child?.resumeReadDetail?.();suspended=false;}
      if(state.kind==='ready'||state.kind==='legacy'){writeRequested=false;close();return;}
      if(!writeRequested){close();return;}
    }else{
      if(state.kind==='unknown'){
        // An active recheck masks private data and closes body-mounted dialogs,
        // while retaining the read view for a successful authorization result.
        if(child&&!suspended){child.suspendForAccessCheck?.();suspended=true;}
        content.inert=true;content.style.visibility='hidden';close();pending.hidden=false;
        return;
      }
      // Failed identity checks discard all private data and detached dialogs.
      content.hidden=true;content.inert=false;content.style.visibility='';suspended=false;lastReadKind=null;clearContent();onWalletReadDenied?.();
    }
    pending.hidden=true;
    if(!dialog){
      dialog=make('dialog');dialog.className='wallet-access-dialog';dialog.setAttribute('aria-labelledby','wallet-access-title');
      dialog.addEventListener('cancel',event=>{event.preventDefault();if(['verify','setup'].includes(gate.state().kind)){writeRequested=false;close();}else exit();});
      document.body.append(dialog);
      background=document.querySelector('#app');if(background){background.inert=true;background.classList.add('wallet-access-obscured');}
      previousOverflow=document.body.style.overflow;document.body.style.overflow='hidden';dialog.showModal();
    }
    if(dialogKind===state.kind&&['verify','setup'].includes(state.kind)&&!state.error)return;
    dialogKind=state.kind;setup?.dispose?.();setup=null;dialog.replaceChildren();
    const title=make('h2',panelTitle);title.id='wallet-access-title';dialog.append(title);
    const message=make('p',({unknown:'正在确认钱包验证状态…',verify:'请验证身份以操作。验证成功后60分钟内无需重复验证；原操作需由您再次提交。',setup:'请先配置钱包验证凭据，再验证以操作。钱包资料仍可查看。',login:'后台登录已失效，请重新登录。',forbidden:'当前账号无权访问USDT提现与支付。',network:'无法确认钱包验证状态，敏感内容已隐藏。请检查网络后重试。'})[state.kind]);message.textContent=message.textContent.replaceAll('USDT提现与支付',panelTitle);dialog.append(message);
    const button=(label,fn)=>{const b=make('button',label);b.type='button';b.className='admin-secondary';b.addEventListener('click',fn);return b;};
    if(state.kind==='verify'){
      const form=make('form'),input=make('input'),label=make('label',state.auth_mode==='totp'?'当前六位验证码':'操作密码');
      input.type='password';input.name=state.auth_mode==='totp'?'mfa_proof':'operation_password';input.required=true;input.autocomplete='off';input.className='admin-filter';if(state.auth_mode==='totp'){input.pattern='[0-9]{6}';input.inputMode='numeric';}label.append(input);
      const submit=make('button','验证以操作');submit.type='submit';submit.className='admin-primary';
      form.append(label,submit);form.addEventListener('submit',async event=>{event.preventDefault();if(submit.disabled)return;const proof={[input.name]:input.value};input.value='';submit.disabled=true;const ok=await gate.verify(proof);for(const key of Object.keys(proof))delete proof[key];submit.disabled=false;if(ok)channel?.postMessage('changed');});dialog.append(form);
      if(state.error)dialog.append(make('p',state.error));queueMicrotask(()=>input.focus());
    }else if(state.kind==='setup'){
      setup=renderSetup?.(api,()=>gate.check(),state);if(setup)dialog.append(setup);
      dialog.append(button('配置完成，检查验证状态',()=>gate.check()));
    }else if(state.kind==='login')dialog.append(button('重新登录',()=>{close();onLogin?.();}));
    else if(state.kind==='network')dialog.append(button('重试验证状态',()=>gate.check()));
    dialog.append(make('p','未确认请求按账号保留。验证后仅查询当前状态，不会自动重放资金操作。'),button('刷新当前操作状态',()=>gate.check()),button('返回其他后台页面',exit));
  }
  const gate=createWalletAccess({api,actorId:actor?.id,getActorId:()=>actor?.id,onChange:show});
  const accessController={
    canWrite:()=>{if(!sameSession()){invalidateSession();return false;}return !pollPending&&gate.allowed();},
    usesGrant:()=>gate.state().kind!=='legacy',
    async requestWriteGrant(){if(!sameSession()){invalidateSession();return false;}if(pollPending)return false;if(gate.allowed())return true;if(!gate.readAllowed())return false;writeRequested=true;show(gate.state());return false;}
  };
  const guarded=new Proxy(api,{get(target,key){const value=target[key];if(typeof value!=='function')return value;return async(...args)=>{
    if(!sameSession()){invalidateSession();throw failure('WALLET_ACCESS_REQUIRED');}
    const invoke=async()=>{const result=await value.apply(target,args);if(!sameSession()){invalidateSession();throw failure('WALLET_ACCESS_REQUIRED');}return result;};
    if(key==='getModule')return args[0]==='wallet'?gate.read(invoke):Promise.reject(failure('WALLET_ACCESS_REQUIRED'));
    if(WALLET_READ_METHODS.has(key))return gate.read(invoke);
    if(CREDENTIAL_METHODS.has(key)){
      if(!gate.readAllowed())throw failure('WALLET_ACCESS_REQUIRED');
      const result=await invoke();gate.lock();channel?.postMessage('changed');await gate.check();return result;
    }
    if(pollPending)throw failure('WALLET_ACCESS_REQUIRED');
    if(!gate.allowed()){
      await accessController.requestWriteGrant();
      throw failure('WALLET_ACCESS_REQUIRED');
    }
    return gate.guard(invoke);
  };}});
  const recheck=()=>{if(disposed||document.hidden)return Promise.resolve(false);if(pendingRecheck)return pendingRecheck;if(pollPending){pollPending=false;++pollToken;}gate.lock();pendingRecheck=gate.check().finally(()=>{pendingRecheck=null;});return pendingRecheck;};
  const focus=()=>{if(!document.hidden)void recheck();};
  const storage=event=>{if(event.key?.startsWith('chatflow.manual.'))return;recheck();};
  if(channel)channel.onmessage=recheck;
  globalThis.addEventListener('focus',focus);globalThis.addEventListener('storage',storage);document.addEventListener('visibilitychange',focus);
  // Read-only polling discovers server revocation and updates from other tabs.
  poll=setInterval(()=>{if(disposed||document.hidden||pollPending||pendingRecheck||['login','forbidden'].includes(gate.state().kind))return;if(!sameSession()){invalidateSession();return;}pollPending=true;const token=++pollToken;void gate.check().finally(()=>{if(token===pollToken)pollPending=false;});},30000);
  root.exportReadView=()=>!disposed&&sameSession()&&!pendingRecheck&&!pollPending&&gate.readAllowed()?child?.exportReadView?.()??null:null;
  root.refreshOrders=async()=>{if(!sameSession()){invalidateSession();return;}if(gate.readAllowed())await child?.refreshOrders?.();};
  root.refresh=async()=>{await recheck();if(!sameSession()){invalidateSession();return false;}if(!gate.readAllowed())return false;return await child?.refresh?.();};
  root.dispose=()=>{disposed=true;++pollToken;pollPending=false;gate.dispose();channel?.close();clearInterval(poll);globalThis.removeEventListener('focus',focus);globalThis.removeEventListener('storage',storage);document.removeEventListener('visibilitychange',focus);clearContent();close();};
  queueMicrotask(()=>{if(!disposed){show(gate.state());void gate.check();}});
  return root;
}
