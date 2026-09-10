// The server owns authorization. This clock only hides stale private UI earlier.
const failure=code=>Object.assign(Error('钱包验证状态已变化，请重新验证并查询当前状态。'),{code,status:403});
export function createWalletAccess({api,actorId,getActorId=()=>actorId,now=()=>performance.now(),setTimer=setTimeout,clearTimer=clearTimeout,onChange=()=>{}}) {
  let current={kind:'unknown'},deadline=0,timer,disposed=false,generation=0,epoch=0;
  function change(kind,extra={}) {clearTimer(timer);if(kind!=='ready'&&kind!=='legacy')epoch++;current={...current,...extra,kind};onChange(current);}
  function allowed(){
    if(disposed)return false;
    if(getActorId()!==actorId){change('login');return false;}
    if(current.kind==='legacy')return true;
    if(current.kind==='ready'&&now()>=deadline)change('verify');
    return current.kind==='ready';
  }
  function arm(){timer=setTimer(()=>{if(allowed())arm();},Math.max(1,deadline-now()));}
  function accept(value,started){
    if(value?.enabled===false){change('legacy',{enabled:false});return;}
    if(value?.enabled!==true||!['operation_password','totp'].includes(value.auth_mode)||typeof value.configured!=='boolean')throw failure('INVALID_ACCESS_STATUS');
    if(!value.verified){change(value.configured?'verify':'setup',value);return;}
    const remaining=Date.parse(value.expires_at)-Date.parse(value.server_time);
    if(!Number.isFinite(remaining)||remaining>3600000)throw failure('INVALID_ACCESS_STATUS');
    // Subtract the entire request duration, conservatively accounting for transit.
    deadline=started+remaining;
    change(deadline>now()?'ready':'verify',value);if(current.kind==='ready')arm();
  }
  function reject(error){
    if(error?.status===401||['AUTH_REQUIRED','ACCESS_TOKEN_INVALID','ADMIN_SESSION_CHANGED','UNAUTHORIZED'].includes(error?.code))change('login');
    else if(error?.code==='WALLET_ACCESS_REQUIRED')change('verify');
    else if(error?.status===403&&!['OPERATION_PASSWORD_INVALID','OPERATION_PASSWORD_NOT_CONFIGURED','MFA_INVALID','MFA_REPLAYED','TOTP_INVALID','TOTP_REPLAYED','INVALID_ACCESS_STATUS'].includes(error?.code))change('forbidden');
    else change(current.kind==='verify'&&error?.code!=='NETWORK_ERROR'?'verify':'network',{error: error?.message??'暂时无法确认验证状态，请重试。'});
  }
  async function update(call){const revision=++generation,started=now();try{const value=await call();if(disposed||revision!==generation)return false;if(getActorId()!==actorId){change('login');return false;}accept(value,started);return allowed();}catch(error){if(!disposed&&revision===generation)reject(error);return false;}}
  return {
    state:()=>current,allowed,
    check:()=>update(()=>api.getWalletAccess()),
    verify:proof=>update(()=>api.verifyWalletAccess(proof)),
    lock(){if(!disposed){++generation;change('unknown');}},
    async guard(call,{credentialChange=false}={}){if(!allowed())throw failure('WALLET_ACCESS_REQUIRED');const version=epoch;try{const value=await call();if(!allowed()||version!==epoch)throw failure('WALLET_ACCESS_REQUIRED');return value;}catch(error){if(!disposed&&current.kind!=='legacy'&&version===epoch&&!(credentialChange&&error?.code==='RECENT_LOGIN_REQUIRED')&&(['WALLET_ACCESS_REQUIRED','AUTH_REQUIRED','ACCESS_TOKEN_INVALID','UNAUTHORIZED'].includes(error?.code)||[401,403].includes(error?.status)))reject(error);throw error;}},
    dispose(){disposed=true;++generation;++epoch;clearTimer(timer);}
  };
}

export function walletAccessPanel(api,{actor,renderContent,renderSetup,onExit,onLogin}={}) {
  const make=(tag,text)=>{const el=document.createElement(tag);if(text!==undefined)el.textContent=text;return el;};
  const root=make('section');root.className='admin-wallet-access';
  const content=make('div');root.append(content);
  let child,dialog,disposed=false,background,previousOverflow,poll,setup,dialogKind;
  const channel=typeof BroadcastChannel==='function'?new BroadcastChannel('chatflow-wallet-access'):null;
  function clearContent(){child?.dispose?.();child=null;content.replaceChildren();}
  function close(){setup?.dispose?.();setup=null;dialogKind=null;if(dialog){dialog.close();dialog.remove();dialog=null;}if(background){background.inert=false;background.classList.remove('wallet-access-obscured');background=null;}if(previousOverflow!==undefined){document.body.style.overflow=previousOverflow;previousOverflow=undefined;}}
  const exit=()=>{close();onExit?.();};
  function show(state){
    if(disposed)return;
    if(state.kind==='ready'||state.kind==='legacy'){
      close();content.hidden=false;
      if(!child){child=renderContent(guarded,state.kind==='ready');content.append(child);}
      return;
    }
    // Remove sensitive nodes, including detached detail dialogs, before adding blur.
    content.hidden=true;clearContent();
    if(!dialog){
      dialog=make('dialog');dialog.className='wallet-access-dialog';dialog.setAttribute('aria-labelledby','wallet-access-title');
      dialog.addEventListener('cancel',event=>{event.preventDefault();exit();});
      document.body.append(dialog);
      background=document.querySelector('#app');if(background){background.inert=true;background.classList.add('wallet-access-obscured');}
      previousOverflow=document.body.style.overflow;document.body.style.overflow='hidden';dialog.showModal();
    }
    if(dialogKind===state.kind&&['verify','setup'].includes(state.kind)&&!state.error)return;
    dialogKind=state.kind;setup?.dispose?.();setup=null;dialog.replaceChildren();
    const title=make('h2','USDT提现与支付');title.id='wallet-access-title';dialog.append(title);
    const message=make('p',({unknown:'正在确认钱包验证状态…',verify:'请验证身份以访问USDT提现与支付。验证成功后60分钟内无需重复验证。',setup:'请先配置钱包验证凭据，完成后验证并进入。',login:'后台登录已失效，请重新登录。',forbidden:'当前账号无权访问USDT提现与支付。',network:'无法确认钱包验证状态，敏感内容已隐藏。请检查网络后重试。'})[state.kind]);dialog.append(message);
    const button=(label,fn)=>{const b=make('button',label);b.type='button';b.className='admin-secondary';b.addEventListener('click',fn);return b;};
    if(state.kind==='verify'){
      const form=make('form'),input=make('input'),label=make('label',state.auth_mode==='totp'?'当前六位验证码':'操作密码');
      input.type='password';input.name=state.auth_mode==='totp'?'mfa_proof':'operation_password';input.required=true;input.autocomplete='off';input.className='admin-filter';if(state.auth_mode==='totp'){input.pattern='[0-9]{6}';input.inputMode='numeric';}label.append(input);
      const submit=make('button','验证并进入');submit.type='submit';submit.className='admin-primary';
      form.append(label,submit);form.addEventListener('submit',async event=>{event.preventDefault();if(submit.disabled)return;const proof={[input.name]:input.value};input.value='';submit.disabled=true;const ok=await gate.verify(proof);for(const key of Object.keys(proof))delete proof[key];submit.disabled=false;if(ok)channel?.postMessage('changed');});dialog.append(form);
      if(state.error)dialog.append(make('p',state.error));queueMicrotask(()=>input.focus());
    }else if(state.kind==='setup'){
      setup=renderSetup?.(api,()=>gate.check());if(setup)dialog.append(setup);
      dialog.append(button('配置完成，检查验证状态',()=>gate.check()));
    }else if(state.kind==='login')dialog.append(button('重新登录',()=>{close();onLogin?.();}));
    else if(state.kind==='network')dialog.append(button('重试验证状态',()=>gate.check()));
    dialog.append(make('p','未确认请求按账号保留。验证后仅查询当前状态，不会自动重放资金操作。'),button('刷新当前操作状态',()=>gate.check()),button('返回其他后台页面',exit));
  }
  const gate=createWalletAccess({api,actorId:actor?.id,onChange:show});
  const guarded=new Proxy(api,{get(target,key){const value=target[key];if(typeof value!=='function')return value;return async(...args)=>{const credentialChange=['setWalletOperationPassword','enrollWalletMfa','enableWalletMfa','abortWalletMfaEnrollment'].includes(key);const result=await gate.guard(()=>value.apply(target,args),{credentialChange});if(credentialChange){gate.lock();channel?.postMessage('changed');await gate.check();}return result;};}});
  const recheck=()=>{if(disposed)return;gate.lock();if(!document.hidden)void gate.check();};
  const focus=()=>{if(!document.hidden)recheck();};
  const storage=event=>{if(event.key?.startsWith('chatflow.manual.'))return;recheck();};
  if(channel)channel.onmessage=recheck;
  globalThis.addEventListener('focus',focus);globalThis.addEventListener('storage',storage);document.addEventListener('visibilitychange',recheck);
  // Read-only polling discovers server revocation and updates from other tabs.
  poll=setInterval(()=>{if(!disposed&&!document.hidden&&!['setup','login','forbidden'].includes(gate.state().kind))void gate.check();},30000);
  root.refresh=async()=>{if(!await gate.check())return false;return await child?.refresh?.();};
  root.dispose=()=>{disposed=true;gate.dispose();channel?.close();clearInterval(poll);globalThis.removeEventListener('focus',focus);globalThis.removeEventListener('storage',storage);document.removeEventListener('visibilitychange',recheck);clearContent();close();};
  queueMicrotask(()=>{if(!disposed){show(gate.state());void gate.check();}});
  return root;
}
