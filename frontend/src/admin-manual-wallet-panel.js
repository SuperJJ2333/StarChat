// Manual operations never sign or broadcast; API/ledger state is authoritative.
import {processIncident, incidentSummary, incidentError, incidentTime, diagnosticSummary, fundControlError} from './wallet-incident-workflow.js?v=20260928-wallet-monitor-t2';
import {detailDialog} from './admin-detail-dialog.js';
const SAFE_METADATA = new Set(['expected_digest', 'txid', 'log_index', 'reason_code', 'expected_version', 'clearance_digest', 'credential_id', 'expected_epoch', 'snapshot_digest','preparation_id','manifest_digest','no_unregistered_payments','notice_received']);
const OWNER_PURPOSES = Object.freeze({
  test: Object.freeze({label:'钱包测试转出', reason_code:'OWNER_TEST_DRAW', reason_detail:'官方钱包持有人测试转出'}),
  payment: Object.freeze({label:'对外付款', reason_code:'OWNER_EXTERNAL_PAYMENT', reason_detail:'官方钱包持有人对外付款'})
});
export function exactUsdt(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)\.[0-9]{6}$/.test(value)) throw new Error('金额格式异常，操作已关闭');
  return value;
}
function ownerAmount(value) {
  if (typeof value !== 'string' || value.length>78 || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error('链上金额格式异常，申报已关闭');
  const units=BigInt(value);
  if(units<=0n) throw new Error('链上金额格式异常，申报已关闭');
  return `${units/1000000n}.${String(units%1000000n).padStart(6,'0')}`;
}
const ownerPurposeForCode=code=>Object.values(OWNER_PURPOSES).find(purpose=>purpose.reason_code===code);
const shortTxid=txid=>`${txid.slice(0,8)}…${txid.slice(-6)}`;
export function operationJournal(storage, actorId) {
  if (!actorId || !storage) throw new Error('无法保存请求恢复记录，资金操作已关闭');
  const prefix = `chatflow.manual.v1:${encodeURIComponent(actorId)}:`;
  return {
    pending(operation) {
      const raw = storage.getItem(prefix + operation);
      return raw ? JSON.parse(raw) : null;
    },
    begin(operation, metadata) {
      if (Object.keys(metadata).some(key => !SAFE_METADATA.has(key))) throw new Error('禁止保存敏感凭证');
      const slot = prefix + operation, serialized = JSON.stringify(metadata);
      const previous = storage.getItem(slot);
      if (previous) {
        const value = JSON.parse(previous);
        if (JSON.stringify(value.metadata) !== serialized) throw new Error('原请求结果尚未确认；请先按原参数恢复请求并刷新状态');
        return value;
      }
      const value = {key: globalThis.crypto.randomUUID(), metadata};
      storage.setItem(slot, JSON.stringify(value));
      if (storage.getItem(slot) !== JSON.stringify(value)) throw new Error('请求恢复记录保存失败');
      return value;
    },
    finish(operation) { storage.removeItem(prefix + operation); }
  };
}
function node(tag, text) {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = String(text);
  return el;
}
function action(label, run) {
  const el = node('button', label); el.type = 'button'; el.className = 'admin-secondary';
  el.addEventListener('click', run); return el;
}
function field(name, label, {secret = false, pattern} = {}) {
  const input = node('input'); input.name = name; input.type = secret ? 'password' : 'text';
  input.className = 'admin-filter'; input.required = true; input.autocomplete = 'off';
  input.setAttribute('aria-label', label); input.placeholder = label;
  if (pattern) input.pattern = pattern;
  return input;
}
function describe(parent, pairs) {
  const dl = node('dl'); dl.style.overflowWrap = 'anywhere';
  for (const [label, value] of pairs) dl.append(node('dt', label), node('dd', value ?? '—'));
  parent.append(dl);
}
const statusLabel = status => ({REQUESTED:'待领取', CLAIMED:'已领取 · 尚未结算', UNKNOWN:'结果未知 · 尚未结算', SETTLED:'已结算', CANCELLED:'已取消', VOIDED:'已撤销（确认未广播）'}[status] ?? '状态未知');

export function manualWalletPanel(api, {actor, storage, clipboard = globalThis.navigator?.clipboard, onReauthenticate, unifiedRefresh = false, walletAccess = false, accessController, securityOnly = false, onSecurityChanged} = {}) {
  const root = node('section'); root.className = 'admin-card admin-manual-wallet-panel';
  const heading=node('header');heading.className='wallet-heading';
  const intro=node('div');intro.append(node('p','TRON · 人工签名'),node('h3','USDT 钱包'),node('p','核对每笔出款，让每一步都有据可查。'));
  const badge=node('span','imToken 人工付款');badge.className='wallet-mode-badge';heading.append(intro,badge);root.append(heading);
  const authentication = node('section'); authentication.setAttribute('role','alert'); root.append(authentication);
  const workspace=node('div'),primary=node('div'),aside=node('aside');workspace.className='wallet-workspace';primary.className='wallet-main';aside.className='wallet-aside';workspace.append(primary,aside);root.append(workspace);
  let authMode=api.getWalletOperationSecurity?'loading':'totp',operationConfigured=false;
  const credentialField=()=>authMode==='operation_password'?field('operation_password','操作密码',{secret:true}):field('mfa_proof','当前六位验证码',{secret:true,pattern:'[0-9]{6}'});
  const credentialFields=()=>walletAccess?[]:[credentialField()];
  const credentialPayload=values=>walletAccess?{}:authMode==='operation_password'?{operation_password:values.operation_password}:{mfa_proof:values.mfa_proof};
  const secretInputs = new Set(); let disposed = false, refreshing = false, writing = false, reading = 0, reauthenticating = false;
  const descendants = el => [el, ...Array.from(el.children ?? []).flatMap(descendants)];
  const forms = () => [...new Set([...descendants(root), ...(incidentModal ? descendants(incidentDetail) : []), ...(payoutModal ? descendants(detail) : [])])].filter(el => el.tagName === 'FORM' || el.tag === 'form');
  const inputsOf = el => descendants(el).filter(el => el.tagName === 'INPUT' || el.tag === 'input');
  const rawApi=api;
  api=new Proxy(rawApi,{get(target,key){const value=target[key];
    if(typeof value!=='function'||!String(key).startsWith('get'))return value;
    return async(...args)=>{reading++;try{return await value.apply(target,args);}finally{reading--;}};
  }});
  const refreshAction = (label, run) => unifiedRefresh ? [] : [action(label, run)];
  const clearStale = parent => {
    parent.replaceChildren(...Array.from(parent.children).filter(el=>el.className!=='wallet-stale'));
  };
  const stale = (parent, message) => {
    clearStale(parent);
    const notice=node('p', `${message} 上次数据已过期，请刷新重试。`);notice.className='wallet-stale';parent.append(notice);
    for (const el of descendants(parent)) if (el.type === 'submit') el.disabled = true;
    return false;
  };
  let securitySnapshot, mfaSnapshot, selectedOrder, selectedIncident, orderCursor, incidentCursor;
  let ownerConfirmModal, ownerPreviewed, ownerCandidate, ownerPreviewGeneration=0, ownerPendingQueried=false;
  let ownerTxidInput, ownerPurposeInput, ownerAttestation, ownerState;

  function authFailure(error) {
    if (disposed || !(error?.status === 401 || ['RECENT_LOGIN_REQUIRED','AUTH_REQUIRED','UNAUTHORIZED'].includes(error?.code))) return;
    authentication.replaceChildren(node('p','会话失效或需要近期登录。请重新登录后刷新当前操作状态；未确认请求会按账号保留，不会自动重放。'));
    if (typeof onReauthenticate === 'function') authentication.append(action('重新登录',async()=>{
      if (reauthenticating) return;
      if (error?.code === 'RECENT_LOGIN_REQUIRED') {
        reauthenticating=true;
        for (const input of secretInputs) input.value = '';
        try {
          const result = onReauthenticate();
          if (result && typeof result.then === 'function') {
            const authenticated = await result;
            if (authenticated !== false) { authentication.replaceChildren(); await root.refresh(); }
            return;
          }
        } catch { authentication.append(node('p','重新验证未完成，请重试。')); return; }
        finally { reauthenticating=false; }
      } else onReauthenticate();
      disposed = true; ++mfaGeneration; ++listGeneration; ++detailGeneration; ++incidentGeneration; ++incidentSelection;
      for (const input of secretInputs) input.value = '';
      secretInputs.clear(); root.replaceChildren();
    }));
    if(payoutModal)detail.append(authentication);
  }
  let journal;
  try { journal = operationJournal(storage ?? globalThis.localStorage, actor?.id); } catch { root.append(node('p', '无法保存管理员请求恢复记录，写操作已关闭。')); }
  const commandForms = [];
  function syncCommandForms() { for (const entry of commandForms) entry.submit.disabled = entry.blocked(); }
  function commandForm(parent, name, label, inputs, run, operation) {
    for (const input of inputs) if (input.type === 'password') secretInputs.add(input);
    const form = node('form'); form.name = name; form.className = 'admin-command-form';
    const blocked=()=>!journal||authMode==='loading'||authMode==='unavailable'||authMode==='operation_password'&&!operationConfigured&&name!=='operation-password';
    const submit = node('button', label); submit.type = 'submit';
    const critical=['claim','txid','incident-process'].includes(name)||name.startsWith('control-')||name.startsWith('handover-');
    submit.className = critical?'admin-primary wallet-critical-action':'admin-primary'; submit.disabled = blocked();
    commandForms.push({ name, submit, blocked });
    const state = node('p'); state.setAttribute('role', 'status');
    if (journal && operation) {
      const pending = journal.pending(operation);
      if (pending) {
        for (const input of inputs) if (input.type !== 'password' && pending.metadata[input.name] !== undefined) input.value = pending.metadata[input.name];
        state.textContent = walletAccess?'已恢复未确认请求；请先刷新服务端状态，核对原参数后确认继续。':'已恢复未确认请求；请先刷新服务端状态，再输入验证凭证重试。';
      }
    }
    form.commandState=state;
    form.append(...inputs.map(input=>{
      const label=node('label');label.className=input.type==='checkbox'?'wallet-check':'wallet-field';
      const caption=node('span',input.getAttribute?.('aria-label')??input['aria-label']);
      label.append(...(input.type==='checkbox'?[input,caption]:[caption,input]));return label;
    }), submit, state); parent.append(form);
    form.addEventListener('submit', async event => {
      event.preventDefault(); if (disposed || refreshing || writing || reading || reauthenticating || submit.disabled || blocked()) return;
      if(accessController&&!accessController.canWrite()&&name!=='operation-password'&&!name.startsWith('mfa-')){
        state.textContent='请先验证以操作。验证后请核对当前状态并重新提交；系统不会自动执行原操作。';
        await accessController.requestWriteGrant();
        return;
      }
      writing = true; submit.disabled = true; state.textContent = '正在处理，请稍候…';
      root.setAttribute('aria-busy','true');
      refreshStatus.textContent='操作正在处理；点击刷新会在完成后自动刷新。';
      const values = Object.fromEntries(inputs.map(input => [input.name, input.type === 'password' ? input.value : input.value.trim()]));
      // Erase secrets before awaiting a network request, including failures.
      inputs.filter(input => input.type === 'password').forEach(input => { input.value = ''; });
      try {
        for (const input of inputs) if (!values[input.name] || input.type==='checkbox'&&!input.checked || input.pattern && !new RegExp(`^(?:${input.pattern})$`).test(values[input.name])) throw new Error('请完整填写有效参数');
        await run(values, state);
      } catch (error) {
        authFailure(error);
        if (name==='operation-password') {
          state.textContent=error.code==='RECENT_LOGIN_REQUIRED'?'请重新登录，再继续设置操作密码。':
            error.code==='NETWORK_ERROR'?'网络连接中断，操作密码设置结果尚未确认。请检查网络并使用右上角刷新图标刷新安全设置；重试须保留原参数。':
            error.code==='OPERATION_PASSWORD_INPUT_INVALID'?error.message:
            error.code==='VALIDATION_ERROR'?'设置参数未通过校验：新操作密码须为 12–128 字符，请核对填写后继续。':
            `操作密码设置未确认：${error.code||error.message||'REQUEST_FAILED'}。请刷新安全设置后继续。`;
        } else if (name.startsWith('incident-')) {
          state.textContent=error.message==='请完整填写有效参数'?'请勾选接手确认并输入有效凭证。':incidentError(error);
        } else if (name.startsWith('mfa-')) {
          state.textContent = error.code === 'RECENT_LOGIN_REQUIRED'
            ? '近期登录验证已过期。请点击“重新登录”，登录后刷新 MFA 状态再继续。'
            : `MFA 操作未确认：${error.code || 'REQUEST_FAILED'}。请先刷新 MFA 状态，再继续操作。`;
        } else if (name.startsWith('handover-') && error.code==='HANDOVER_EVIDENCE_UNAVAILABLE'
            || name==='control-resume' && error.code==='MANUAL_CONTROL_EVIDENCE_UNAVAILABLE') {
          const resuming=name==='control-resume';
          const operationLabel=resuming?'资金恢复':'交接';
          const evidence=error.fields?.find?.(item=>item?.type===(resuming?'wallet.control.evidence':'wallet.handover.evidence'))?.msg;
          const explanation={
            MANUAL_COVERAGE_PENDING:'业务流水扫描尚未追平链上监控',
            MANUAL_SOURCE_PENDING:'链上监控正在等待稳定的对账结果',
            MONITOR_SCAN_BUSY:'监控核验正在进行',
            MANUAL_SOURCE_CHANGED:'链上监控快照已更新，需要重新核验',
            MANUAL_RESERVE_CHANGED:'储备记录已更新，需要重新核验',
            HANDOVER_PROOF_DEADLINE:'本轮交接核验已超时',
            MANUAL_CONTROL_PROOF_DEADLINE:'本轮资金恢复核验已超时'
          }[evidence]??`${operationLabel}证据尚未通过核验`;
          state.textContent=`${explanation}。本次${operationLabel}未提交，资金仍暂停。请刷新${resuming?'资金控制':'交接'}状态；重试时保留原参数和请求编号。`;
        } else if(name.startsWith('control-')) {
          state.textContent=error.message==='请完整填写有效参数'?'请勾选确认并输入有效凭证。':fundControlError(error);
        } else if(name==='owner-transfer') {
          state.textContent=error.message==='请完整填写有效参数'?
            !ownerPurposeInput?.value?'请选择转出用途。':'请填写完整交易哈希并确认该转出由本人操作。':
            '预检未确认；请核对链上证据后重新预检，未提交申报。';
        } else {
          state.textContent = `操作未确认：${error.code || 'REQUEST_FAILED'}。结果未知时请先刷新状态，禁止重复付款；重试必须保留原参数。`;
        }
      }
      finally {
        writing = false; submit.disabled = blocked();root.setAttribute('aria-busy','false');
        if(queuedRefresh) {
          const pending=queuedRefresh;queuedRefresh=null;
          try { pending.resolve(await root.refresh()); } catch { pending.resolve(false); }
        } else if(!disposed) refreshStatus.textContent='本次处理已结束，请查看操作结果。可刷新核对最新状态。';
      }
    });
    return form;
  }
  async function mutate(operation, metadata, call) {
    const entry = journal.begin(operation, metadata);
    const result = await call({idempotencyKey:entry.key});
    journal.finish(operation); return result;
  }
  const mfa = node('section'); mfa.id='wallet-security';mfa.className='wallet-surface wallet-security';mfa.setAttribute('aria-label','账户安全设置'); aside.append(mfa);
  let mfaGeneration = 0;
  async function loadSecurity() {
    if(!api.getWalletOperationSecurity) return loadMfa();
    const generation=++mfaGeneration;
    try {
      const current=await api.getWalletOperationSecurity();if(disposed||generation!==mfaGeneration)return;
      if(!['totp','operation_password'].includes(current.auth_mode)||typeof current.configured!=='boolean'||!Number.isSafeInteger(current.version)||current.version<0)throw Error('INVALID_SECURITY_STATE');
      authMode=current.auth_mode;operationConfigured=current.configured;syncCommandForms();
      if(authMode==='totp')return loadMfa();
      const signature=JSON.stringify(current); if(securitySnapshot===signature){clearStale(mfa);for(const el of descendants(mfa))if(el.type==='submit')el.disabled=!journal;return;} securitySnapshot=signature;
      mfa.replaceChildren(node('h4','操作密码'),node('p',current.configured?'已设置 · 仅用于后台敏感操作':'首次设置 · 使用独立于登录密码的密码'),...refreshAction('刷新安全设置',loadSecurity));
      const fields=[field('login_password','当前登录密码',{secret:true})];
      if(current.configured)fields.push(field('current_operation_password','当前操作密码',{secret:true}));
      fields.push(field('new_operation_password','新操作密码（12–128 字符）',{secret:true}),field('confirm_operation_password','再次输入操作密码',{secret:true}));
      const passwordForm=current.configured?node('details'):mfa;
      if(current.configured){passwordForm.className='wallet-password-change';passwordForm.append(node('summary','更改操作密码'));mfa.append(passwordForm);}
      commandForm(passwordForm,'operation-password',current.configured?'更新操作密码':'设置操作密码',fields,async values=>{
        const length=Array.from(values.new_operation_password).length;
        if(length<12||length>128)throw Object.assign(Error('操作密码须为 12–128 字符，请重新填写。'),{code:'OPERATION_PASSWORD_INPUT_INVALID'});
        if(values.new_operation_password!==values.confirm_operation_password)throw Error('两次操作密码不一致');
        const {confirm_operation_password,...body}=values;
        await mutate(`operation-password:${current.version}`,{},options=>api.setWalletOperationPassword(body,options));
        if(onSecurityChanged){await onSecurityChanged();return;} await loadSecurity();await Promise.all([loadOrders(),loadIncidents(),loadControl(),loadHandover()]);
      });
      mfa.append(node('p','密码不会保存到浏览器。更改后，旧授权立即失效。'));
    }catch(error){if(disposed||generation!==mfaGeneration)return;authMode='unavailable';syncCommandForms();authFailure(error);if(!disposed&&generation===mfaGeneration)return stale(mfa,'安全设置暂不可用，敏感操作已关闭。');}
  }
  async function loadMfa() {
    if (disposed) return;
    const generation = ++mfaGeneration;
    try {
      const current = await api.getWalletMfaStatus(); if (disposed || generation !== mfaGeneration) return;authMode='totp';syncCommandForms();
      const signature=JSON.stringify(current);if(mfaSnapshot===signature){clearStale(mfa);for(const el of descendants(mfa))if(el.type==='submit')el.disabled=!journal;return;}mfaSnapshot=signature;
      mfa.replaceChildren(node('h4','动态验证 MFA'), ...refreshAction('刷新 MFA 状态',loadMfa));
      if (!current.configured) {
        mfa.append(node('p','服务端 MFA 密钥尚未就绪，启用和验证码核验暂不可用。'));
        if(current.enabled) mfa.append(node('p','账户已有启用的验证器，须恢复原服务端密钥；此入口不能重置。'));
        else if(current.pending_credential_id) {
          mfa.append(node('p','账户有尚未启用的旧注册。如需放弃该注册，可用当前密码取消；不会重置已启用验证器。'));
          renderPending(current.pending_credential_id, false);
        }
        return;
      }
      if (current.enabled) { mfa.append(node('p',walletAccess?'动态验证已启用。钱包验证有效期内无需重复输入验证码。':'动态验证已启用。敏感操作请输入当前六位验证码。')); return; }
      if (current.pending_credential_id) {
        mfa.append(node('p','存在待启用凭证。已添加验证器可继续验证；密钥已丢失时请用密码终止待启用凭证后重新设置。'));
        renderPending(current.pending_credential_id); return;
      }
      commandForm(mfa,'mfa-enroll','创建动态验证凭证',[field('password','当前登录密码',{secret:true})],async values => {
        const result = await mutate('mfa:enroll',{}, options=>api.enrollWalletMfa(values,options));
        if (disposed) return;
        mfa.replaceChildren(node('h4','将密钥添加到验证器'),node('p','仅在本页显示；不会保存至浏览器。完成或离开页面后请清除。'));
        describe(mfa,[['验证器密钥',result.secret],['配置 URI',result.provisioning_uri]]);
        mfa.append(action('隐藏密钥并刷新状态',loadMfa)); renderPending(result.credential_id);
      });
    } catch (error) { if(disposed||generation!==mfaGeneration)return;authMode='unavailable';authFailure(error); if (generation === mfaGeneration) return stale(mfa,'MFA 状态读取失败。'); }
  }
  function renderPending(credentialId, canEnable=true) {
    if(canEnable) commandForm(mfa,'mfa-enable','验证并启用',[field('code','验证器六位验证码',{secret:true,pattern:'[0-9]{6}'})],async values=>{
      await mutate(`mfa:enable:${credentialId}`,{credential_id:credentialId},options=>api.enableWalletMfa({...values,credential_id:credentialId},options)); await loadMfa();if(onSecurityChanged)await onSecurityChanged();
    });
    commandForm(mfa,'mfa-abort','终止待启用凭证',[field('password','当前登录密码',{secret:true})],async values=>{
      await mutate(`mfa:abort:${credentialId}`,{credential_id:credentialId},options=>api.abortWalletMfaEnrollment({...values,credential_id:credentialId},options)); await loadMfa();if(onSecurityChanged)await onSecurityChanged();
    });
  }
  const orders = node('section'), detail = node('section'); detail.setAttribute('aria-live','polite');
  let payoutModal;
  const listState = node('p'); listState.setAttribute('role','status');
  const queue=node('section');queue.id='wallet-payout';queue.className='wallet-surface wallet-queue';orders.className='wallet-orders';detail.className='wallet-detail';
  queue.append(node('h4','用户提现申请 · 人工出款队列'),node('p','此队列来自用户提现申请。核对锁定信息，领取后在 imToken 完成签名；人工出款订单编号与链上交易哈希分别核对。'),...refreshAction('刷新出款队列',()=>loadOrders()),listState,orders,detail);primary.append(queue);
  let listGeneration=0, detailGeneration=0;
  async function loadOrders(cursor = orderCursor) {
    if (disposed) return;
    const generation=++listGeneration; orderCursor=cursor; listState.textContent='正在加载出款…';
    try {
      const page=await api.getManualPayouts({limit:25,cursor}); if(generation!==listGeneration) return;
      orders.replaceChildren();
      listState.textContent=`${page.items.length?'金额均为 USDT，保留六位小数。':'暂无人工出款。'}队列读取于 ${formatBeijingTime(Date.now())}。`;
      for(const item of page.items) {
        const row=node('article'),summary=node('div');summary.className='wallet-order-summary';
        const status=node('span',statusLabel(item.status));status.className=item.status==='UNKNOWN'?'wallet-order-state is-unknown':'wallet-order-state';
        summary.append(node('p','来源：用户提现申请'),node('p',`人工出款订单编号：${item.id}`),node('strong',`${exactUsdt(item.amount)} USDT`),status);
        row.append(summary,action('查看出款',()=>showOrder(item.id))); orders.append(row);
      }
      if(page.next_cursor) orders.append(action('下一页出款',()=>loadOrders(page.next_cursor)));
    } catch (error) { if(disposed||generation!==listGeneration)return;authFailure(error); if(generation===listGeneration) { listState.textContent='出款加载失败，上次数据已过期，请刷新重试。'; return false; } }
  }
  async function showOrder(id) {
    if (disposed) return;
    const generation=++detailGeneration; selectedOrder=id;
    detail.replaceChildren(node('p','正在加载出款详情…'));
    if(!payoutModal)payoutModal=detailDialog('出款详情',detail,{onClose:()=>{
      payoutModal=null;selectedOrder=undefined;++detailGeneration;
      for(const input of inputsOf(detail))if(input.type==='password'){input.value='';secretInputs.delete(input);}
      if(root.insertBefore)root.insertBefore(authentication,workspace);else root.append(authentication);
      detail.replaceChildren();
    }});
    try {
      const item=await api.getManualPayout(id); if(generation!==detailGeneration) return;
      const s=item.snapshot;
      for(const name of ['amount','fee','hold','receive']) exactUsdt(s[name]);
      const asset=s.funding_asset??'USDT',payable=exactUsdt(item.final_receive??s.receive);
      const fundingAmount=asset==='CAIBI'?s.funding_amount:s.amount;
      const fundingValid=asset==='CAIBI'
        ?typeof fundingAmount==='string'&&/^(0|[1-9][0-9]*)\.[0-9]{2}$/.test(fundingAmount)&&s.amount===`${fundingAmount}0000`
        :asset==='USDT'&&s.amount===item.amount;
      if(s.fee!=='0.000000'||!fundingValid||s.hold!==item.amount||s.receive!==item.amount||! /^[a-f0-9]{64}$/.test(item.digest)) throw new Error('Invalid snapshot');
      detail.replaceChildren(node('h4',`用户提现申请 · 人工出款订单 ${item.id}`),node('p',statusLabel(item.status)),...refreshAction('刷新此出款',()=>showOrder(id)));
      describe(detail,[['来源','用户提现申请'],['人工出款订单编号',item.id],['收款地址（锁定）',s.target_address],['官方出款地址（锁定）',s.official_address],['网络',s.network],['合约',s.contract],[`申请本金 ${asset==='CAIBI'?'点钻':'USDT'}`,fundingAmount],['服务费 USDT',s.fee],['总冻结 USDT',s.hold],['原到账 USDT',s.receive],['最终应付 USDT',payable],['不可变报价摘要',item.digest],['绑定版本',s.binding_version],['官方配置版本',s.official_config_version],['报价到期',formatBeijingTime(s.expires_at)],['领取管理员',item.claimed_by],['候选链上交易哈希',item.candidate_txid],['结算链上交易哈希',item.settlement_txid],['复核原因',item.review_reason]]);
      for(const candidate of item.candidates ?? []) describe(detail,[['候选历史链上交易哈希',candidate.txid],['操作者',candidate.actor_id],['原因',candidate.reason_code],['时间',formatBeijingTime(candidate.created_at)]]);
      if(actor?.id!==s.owner_admin_id) { detail.append(node('p','当前账号不是官方钱包拥有者，仅可查看。')); return; }
      if(item.status==='REQUESTED') {
        detail.append(node('p','请核对以上完整快照。确认摘要并领取后，才可按指令在 imToken 付款。'));
        commandForm(detail,'claim','领取付款指令',[...credentialFields()],async values=>{
          await mutate(`${id}:claim`,{expected_digest:item.digest},options=>api.claimManualPayout(id,{...credentialPayload(values),expected_digest:item.digest},options));
          if(generation===detailGeneration) await showOrder(id);
        }, `${id}:claim`);
      }
      if(['CLAIMED','UNKNOWN'].includes(item.status)) {
        detail.append(node('p','已领取或结果未知：禁止重复付款。先查询原交易与本订单；资金继续冻结，回填哈希不代表已结算。'));
        if(item.status==='UNKNOWN'&&!item.candidate_txid&&Number.isSafeInteger(item.version)&&item.version>0){
          detail.append(node('p','仅在确认此单从未签名、从未广播且最新链上复核通过后，才能撤销。撤销会冲回本单冻结及原兑换；不会自动恢复资金。'));
          let preview,needsGrant=accessController?.canWrite()===false;
          if(!needsGrant)try { preview=await api.getVoidUnbroadcastPreview?.(id); } catch(error) {
            authFailure(error);
            needsGrant=error?.code==='WALLET_ACCESS_REQUIRED';
            preview={status:'UNAVAILABLE'};
          }
          if(generation!==detailGeneration)return;
          const evidence=preview?.evidence;
          const ready=preview?.status==='READY'&&typeof evidence?.observation_id==='string'&&Number.isSafeInteger(evidence?.checkpoint);
          if(needsGrant){
            const notice=node('p','撤销预检需要钱包操作权限验证；这不表示链上观察故障。完成验证后，请再次点击下面按钮重新核验。');
            detail.append(notice,action('验证钱包操作权限并重新核验',async()=>{
              if(disposed||generation!==detailGeneration)return;
              if(await accessController?.requestWriteGrant()){
                if(!disposed&&generation===detailGeneration)await showOrder(id);
              }else notice.textContent='请完成钱包操作权限验证，再点击此按钮重新核验；系统不会自动撤销。';
            }));
          }else if(ready){
            detail.append(node('p',`链上观察已覆盖领取时段 · 观察编号 ${evidence.observation_id} · 检查点 ${formatBeijingTime(evidence.checkpoint)}。这是单源观察，仍需本人确认未签名、未广播。`));
            commandForm(detail,'void-unbroadcast','确认未广播并撤销',[field('reason_code','撤销原因代码',{pattern:'[A-Z][A-Z0-9_]{2,79}'}),checkbox('never_signed','我确认此单从未签名'),checkbox('never_broadcast','我确认此单从未广播'),credentialField()],async values=>{
              const metadata={expected_version:item.version,reason_code:values.reason_code};
              const proof=authMode==='operation_password'?{operation_password:values.operation_password}:{mfa_proof:values.mfa_proof};
              const body={...metadata,never_signed:true,never_broadcast:true,...proof};
              await mutate(`${id}:void-unbroadcast`,metadata,options=>api.voidUnbroadcastPayout(id,body,options));
              if(generation===detailGeneration)await showOrder(id);
            },`${id}:void-unbroadcast`);
          }else detail.append(node('p',preview?.status==='INELIGIBLE'?'链上观察或订单状态不满足撤销条件，请核对原交易与订单。':'链上观察暂不可用，撤销操作已关闭；请稍后刷新核验。'));
        }
        if (item.claimed_by !== actor.id) {
          detail.append(node('p','此订单未由当前管理员领取，仅可核查记录；不提供付款指令或哈希提交。'));
          return;
        }
        const copyState=node('p'); copyState.setAttribute('role','status');
        for(const [label,value] of [['复制收款地址',s.target_address],['复制精确金额',payable]]) detail.append(action(label,async()=>{
          try { if(!clipboard) throw new Error('Clipboard unavailable'); await clipboard.writeText(value); copyState.textContent='已复制原始精确值'; }
          catch { copyState.textContent='复制不可用，请从上方完整字段手动复制并核对。'; }
        }));
        detail.append(copyState);
        const correction=Boolean(item.candidate_txid);
        const inputs=[field('txid','完整交易哈希',{pattern:'[a-fA-F0-9]{64}'})];
        if(correction) inputs.push(field('reason_code','更正原因代码',{pattern:'[A-Z][A-Z0-9_]{2,79}'}));
        if(correction||authMode==='operation_password')inputs.push(...credentialFields());
        commandForm(detail,'txid',correction?'追加更正候选哈希':'提交候选哈希',inputs,async values=>{
          const {mfa_proof,operation_password,...metadata}=values;
          const body=correction||authMode==='operation_password'?{...metadata,...credentialPayload(values)}:metadata;
          await mutate(`${id}:${correction?'correct':'txid'}`,metadata,options=>correction?api.correctManualPayoutCandidate(id,body,options):api.submitManualPayoutTxid(id,body,options));
          if(generation===detailGeneration) await showOrder(id);
        }, `${id}:${correction?'correct':'txid'}`);
      }
    } catch (error) { if(disposed||generation!==detailGeneration)return;authFailure(error); if(generation===detailGeneration) return stale(detail,'详情读取或金额校验失败，付款操作已关闭。'); }
  }
  const incidents=node('section'), incidentDetail=node('section'), monitor=node('p'),diagnostics=node('p'),fundSummary=node('p');
  incidentDetail.className='wallet-incident-detail';
  let incidentModal;
  const incidentFilters=node('form');incidentFilters.name='monitoring-filters';incidentFilters.className='admin-filters';const incidentInputs={};
  for(const [key,label,values] of [['status','处理状态',[['','全部状态'],['OPEN','未处理'],['ACKNOWLEDGED','已确认'],['RESOLVED','已结案']]],['severity','事故等级',[['','全部等级'],['P0','P0'],['P1','P1'],['T2','T2']]],['sort','排序',[['opened_desc','发生时间：新到旧'],['opened_asc','发生时间：旧到新'],['updated_desc','最近发现：新到旧']]]]){const select=node('select');select.className='admin-filter';select.setAttribute('aria-label',label);for(const [value,text] of values){const option=node('option',text);option.value=value;select.append(option);}incidentInputs[key]=select;incidentFilters.append(select);}
  const incidentSearch=node('input');incidentSearch.className='admin-filter';incidentSearch.placeholder='事故代码';incidentSearch.setAttribute('aria-label','事故代码');incidentSearch.maxLength=100;incidentInputs.code=incidentSearch;incidentFilters.append(incidentSearch);
  let activeIncidentFilters={},incidentPages=[undefined],incidentPage=0;
  incidentFilters.append(action('查询',()=>loadIncidents(null,{filters:Object.fromEntries(Object.entries(incidentInputs).map(([k,v])=>[k,v.value])),page:0,pages:[null]})),action('重置',()=>loadIncidents(null,{filters:{},page:0,pages:[null],reset:true})));
  incidentFilters.addEventListener('submit',event=>event.preventDefault());
  const monitoring=node('section');monitoring.id='wallet-monitor';monitoring.className='wallet-surface';
  const heartbeat=node('section');heartbeat.className='wallet-monitor-heartbeat';
  heartbeat.append(node('h5','监控心跳与当前状态'),fundSummary,monitor,diagnostics,...refreshAction('刷新监控和事故',()=>loadIncidents(null,{page:0,pages:[null]})));
  const incidentRecords=node('section');incidentRecords.className='wallet-monitor-incidents';
  incidentRecords.append(node('h5','事故记录'),node('p','历史事故与当前检查分别展示。处理事故不会启用资金，恢复需要单独核验。'),incidentFilters,incidents);
  monitoring.append(node('h4','监控与事故'),heartbeat,incidentRecords);primary.append(monitoring);
  if (walletAccess) {
    const ownerTransfer=node('section');ownerTransfer.id='wallet-owner';ownerTransfer.className='wallet-surface';
    const recovery=node('section');recovery.setAttribute('role','status');
    ownerTransfer.append(node('h4','所有者转出申报'),
      node('p','仅申报官方钱包持有人已经完成的转出。预检不会申报或记账；执行后仍须独立检查事故与资金恢复。'));
    ownerTxidInput=field('txid','链上交易哈希（64 位十六进制）',{pattern:'[a-f0-9]{64}'});
    ownerPurposeInput=node('select');ownerPurposeInput.name='purpose';ownerPurposeInput.className='admin-filter';
    ownerPurposeInput.required=true;ownerPurposeInput.setAttribute('aria-label','转出用途');
    for(const [value,label] of [['','请选择转出用途'],...Object.entries(OWNER_PURPOSES).map(([key,purpose])=>[key,purpose.label])]){
      const option=node('option',label);option.value=value;ownerPurposeInput.append(option);
    }
    ownerPurposeInput.value='';
    ownerAttestation=checkbox('ownership_attested','我确认该转出由本人（官方钱包持有人）操作');
    const draftFingerprint=()=>JSON.stringify([ownerTxidInput.value.trim(),ownerPurposeInput.value,
      ownerAttestation.checked,ownerCandidate?.txid===ownerTxidInput.value.trim()?ownerCandidate.log_index:null]);
    const closeOwnerConfirm=()=>{const modal=ownerConfirmModal;ownerConfirmModal=null;ownerPreviewed=null;if(modal)modal.close();};
    const invalidateOwnerPreview=()=>{++ownerPreviewGeneration;closeOwnerConfirm();};
    for(const [input,event] of [[ownerTxidInput,'input'],[ownerPurposeInput,'change'],[ownerAttestation,'change']])
      input.addEventListener(event,()=>{invalidateOwnerPreview();if(input===ownerTxidInput&&ownerCandidate?.txid!==ownerTxidInput.value.trim())ownerCandidate=null;});
    const pendingOwner=()=>{
      if(!journal)return null;
      try {
        const entry=journal.pending('owner-transfer');if(!entry)return null;
        const metadata=entry.metadata;
        if(!/^[0-9a-f-]{36}$/.test(entry.key)||!metadata||
            Object.keys(metadata).sort().join(',')!=='log_index,reason_code,txid'||
            !/^[a-f0-9]{64}$/.test(metadata.txid)||!Number.isSafeInteger(metadata.log_index)||metadata.log_index<0||
            !ownerPurposeForCode(metadata.reason_code))throw Error('Invalid owner recovery record');
        return entry;
      } catch {return {invalid:true};}
    };
    const matchingOwnerRecord=(record,metadata)=>record?.status==='DECLARED'&&record.txid===metadata.txid&&
      record.log_index===metadata.log_index&&record.reason_code===metadata.reason_code&&
      record.reason_detail===ownerPurposeForCode(metadata.reason_code)?.reason_detail&&record.declared_by===actor?.id;
    function renderOwnerRecovery(message) {
      recovery.replaceChildren();
      const pending=pendingOwner();
      if(!pending){if(message)recovery.append(node('p',message));return;}
      if(pending.invalid){recovery.append(node('p','原申报恢复记录无效，写入已关闭；请由管理员核查。'));return;}
      recovery.append(node('p',message??`原申报 ${shortTxid(pending.metadata.txid)} 的结果尚未确认；另一笔申报已关闭。`),
        action('查询原申报状态',async()=>{
          if(disposed||writing||refreshing||reading)return;
          try {
            const current=pendingOwner();if(!current||current.invalid)return;
            const result=await api.getOwnerTransfer(current.metadata.txid);
            if(disposed)return;
            if(result?.txid===current.metadata.txid&&Array.isArray(result.transfers)&&
                result.transfers.some(row=>matchingOwnerRecord(row,current.metadata))){
              journal.finish('owner-transfer');ownerPendingQueried=false;invalidateOwnerPreview();
              renderOwnerRecovery('原申报已按完整定位、用途和操作者确认；没有重新发送写请求。');
              return;
            }
            ownerPendingQueried=true;invalidateOwnerPreview();ownerCandidate=null;
            ownerTxidInput.value=current.metadata.txid;
            ownerPurposeInput.value=Object.entries(OWNER_PURPOSES).find(([,purpose])=>purpose.reason_code===current.metadata.reason_code)[0];
            ownerAttestation.checked=false;
            renderOwnerRecovery('原请求尚未确认成功。只可重新预检同一链上事件；重新勾选所有权后主动确认，沿用原请求编号。');
          } catch(error) {authFailure(error);if(!disposed)renderOwnerRecovery('原申报状态查询失败；不能判定成功或发起另一笔申报。');}
        }));
    }
    async function confirmOwnerTransfer(button,state) {
      if(disposed||refreshing||writing||reading||reauthenticating||button.disabled||!ownerPreviewed)return;
      const current=ownerPreviewed;
      if(current.fingerprint!==draftFingerprint()){
        invalidateOwnerPreview();state.textContent='申报参数已变化，请重新预检并再次确认。';return;
      }
      if(accessController&&!accessController.canWrite()){
        button.disabled=true;invalidateOwnerPreview();state.textContent='钱包验证已失效。验证后重新预检并再次点击确认；系统不会自动申报。';
        await accessController.requestWriteGrant();return;
      }
      writing=true;button.disabled=true;root.setAttribute('aria-busy','true');
      refreshStatus.textContent='申报正在处理；点击刷新会在完成后自动刷新。';
      const metadata={txid:current.payload.txid,log_index:current.snapshot.log_index,reason_code:current.payload.reason_code};
      try {
        const pending=pendingOwner();
        if(pending?.invalid||pending&&!ownerPendingQueried||pending&&JSON.stringify(pending.metadata)!==JSON.stringify(metadata))
          throw Error('原请求结果尚未核清；不能发起另一笔申报');
        const entry=journal.begin('owner-transfer',metadata);
        ownerPendingQueried=false;renderOwnerRecovery();
        const result=await api.executeOwnerTransfer({...current.payload,log_index:current.snapshot.log_index},{idempotencyKey:entry.key});
        if(!matchingOwnerRecord(result,metadata))throw Error('申报响应与原定位不一致');
        journal.finish('owner-transfer');renderOwnerRecovery();closeOwnerConfirm();
        if(!disposed)ownerState.textContent=`已申报（${result.replayed?'原记录':'新记录'}）。请刷新监控和事故，再单独核验资金恢复。`;
      } catch(error) {
        authFailure(error);closeOwnerConfirm();renderOwnerRecovery();
        if(!disposed)ownerState.textContent='申报结果尚未确认。请先查询原申报状态；不得自动重发或提交另一笔。';
      } finally {
        writing=false;root.setAttribute('aria-busy','false');
        if(queuedRefresh){const pending=queuedRefresh;queuedRefresh=null;try{pending.resolve(await root.refresh());}catch{pending.resolve(false);}}
        else if(!disposed)refreshStatus.textContent='本次处理已结束，请核对申报状态。';
      }
    }
    const ownerForm=commandForm(ownerTransfer,'owner-transfer','预检所有者转出',
      [ownerTxidInput,ownerPurposeInput,ownerAttestation],async(values,state)=>{
        invalidateOwnerPreview();
        const purpose=OWNER_PURPOSES[values.purpose];
        if(!purpose){state.textContent='请先选择转出用途。';return;}
        const pending=pendingOwner();
        if(pending?.invalid||pending&&!ownerPendingQueried||pending&&
            (pending.metadata.txid!==values.txid||pending.metadata.reason_code!==purpose.reason_code)){
          state.textContent='原申报结果尚未核清；请先查询原请求状态，不得申报另一笔。';return;
        }
        const selected=ownerCandidate?.txid===values.txid?ownerCandidate:null;
        if(selected&&pending&&selected.log_index!==pending.metadata.log_index){state.textContent='候选事件与原请求不一致，申报已关闭。';return;}
        const payload={txid:values.txid,...(pending?{log_index:pending.metadata.log_index}:selected?{log_index:selected.log_index}:{}),
          reason_code:purpose.reason_code,reason_detail:purpose.reason_detail,ownership_attested:true};
        const fingerprint=draftFingerprint(),generation=++ownerPreviewGeneration;
        try {
          const snapshot=await api.previewOwnerTransfer(payload);
          if(disposed||generation!==ownerPreviewGeneration||fingerprint!==draftFingerprint())return;
          if(!snapshot||snapshot.txid!==values.txid||!Number.isSafeInteger(snapshot.log_index)||snapshot.log_index<0||
              !Array.isArray(snapshot.blockers)||snapshot.reason_code!==purpose.reason_code||
              snapshot.reason_detail!==purpose.reason_detail||snapshot.declared_by!==actor?.id||
              typeof snapshot.to_address!=='string'||!snapshot.to_address)throw Error('预检证据不完整');
          if(snapshot.blockers.length){state.textContent=`预检未通过：${snapshot.blockers.join('、')}。未提交申报。`;return;}
          const amount=ownerAmount(snapshot.amount_units);
          if(payload.log_index!==undefined&&snapshot.log_index!==payload.log_index||selected&&
              (selected.amount!==amount||selected.to_address!==snapshot.to_address))throw Error('链上候选与预检证据不一致');
          const body=node('section');body.append(node('p','请核对实际收款地址、精确金额与用途。预检未产生申报或账本记录。'));
          describe(body,[['交易哈希',shortTxid(values.txid)],['精确金额',`${amount} USDT`],
            ['收款地址',snapshot.to_address],['用途',purpose.label]]);
          const confirm=action('确认申报',()=>confirmOwnerTransfer(confirm,state));confirm.className='admin-primary wallet-critical-action';body.append(confirm);
          ownerPreviewed={payload,snapshot,fingerprint};
          ownerConfirmModal=detailDialog('确认所有者转出申报',body,{onClose:()=>{ownerConfirmModal=null;ownerPreviewed=null;++ownerPreviewGeneration;}});
          state.textContent='预检通过。请在确认窗口核对后，主动点击“确认申报”。';
        } catch(error) {
          if(disposed||generation!==ownerPreviewGeneration)return;
          state.textContent=error?.code==='TRANSFER_SELECTION_REQUIRED'?'该交易包含多笔官方转出，请从上方链上流水选择具体记录。':
            error?.code==='TRANSFER_NOT_FOUND'?'该交易没有可申报的官方转出，请核查链上流水。':
            '预检未通过；链上证据或服务状态需核查，未提交申报。';
        }
      });
    ownerState=ownerForm.commandState;
    ownerTransfer.append(node('p','预检会核对新鲜链上证据与监控覆盖；表单不填写索引、金额或地址。'),recovery);
    renderOwnerRecovery();primary.append(ownerTransfer);
    root.selectOwnerTransferCandidate=value=>{
      if(disposed||pendingOwner()||!value||typeof value.txid!=='string'||!/^[a-f0-9]{64}$/.test(value.txid)||
          !Number.isSafeInteger(value.log_index)||value.log_index<0||typeof value.to_address!=='string'||
          !value.to_address||!Number.isSafeInteger(value.timestamp_ms)||value.timestamp_ms<0)return false;
      try {exactUsdt(value.amount);} catch {return false;}
      invalidateOwnerPreview();ownerCandidate={txid:value.txid,log_index:value.log_index,amount:value.amount,
        to_address:value.to_address,timestamp_ms:value.timestamp_ms};
      ownerTxidInput.value=value.txid;ownerAttestation.checked=false;
      ownerState.textContent='已选择链上观察记录。请核对用途并勾选所有权，再用新鲜链证据预检。';
      return true;
    };
  }
  let reservePolicy;
  let incidentGeneration=0, incidentSelection=0;
  async function loadIncidents(cursor = incidentCursor,{filters=activeIncidentFilters,page=incidentPage,pages=incidentPages,reset=false}={}) {
    if (disposed) return;
    const generation=++incidentGeneration;
    const results=await Promise.allSettled([api.getWalletIncidents({...filters,limit:25,cursor}),api.getWalletMonitorStatus(),api.getManualWalletDiagnostics?api.getManualWalletDiagnostics():Promise.resolve(null)]);
    if(generation!==incidentGeneration) return;
    const [list,status,diagnostic]=results;
    for (const result of results) if (result.status === 'rejected') authFailure(result.reason);
    monitor.textContent=status.status==='fulfilled'?`上次完整资金核验：${incidentTime(status.value.last_success_at)}${status.value.stale?'（需重新核验）':''} · 外部告警${status.value.external_delivery_configured?'已配置':'未配置，恢复前需检查'}`:'完整资金核验记录读取失败，上次数据已过期，请刷新后核实。';
    reservePolicy=diagnostic.status==='fulfilled'?diagnostic.value?.reserve_policy:undefined;
    diagnostics.textContent=diagnosticSummary(diagnostic.status==='fulfilled'?diagnostic.value:null)+(diagnostic.value?.checked_at?` 检查时间：${incidentTime(diagnostic.value.checked_at)}`:'');
    if(list.status==='rejected') return stale(incidents,'事故加载失败。');
    incidentCursor=cursor;activeIncidentFilters=filters;incidentPage=page;incidentPages=pages;
    if(reset)for(const [key,input] of Object.entries(incidentInputs))input.value=key==='sort'?'opened_desc':'';
    incidents.replaceChildren(node('p',`事故列表读取于 ${formatBeijingTime(Date.now())}。`));
    if(!list.value.items.length) incidents.append(node('p','暂无事故记录'));
    const table=node('table');table.className='admin-table';const headers=node('tr'),head=node('thead'),body=node('tbody');for(const label of ['事故','发生时间（北京时间）','等级','处理状态','影响范围','操作'])headers.append(node('th',label));head.append(headers);
    for(const item of list.value.items) { const summary=incidentSummary(item,reservePolicy),row=node('tr');for(const value of [summary.title,incidentTime(item.opened_at),item.severity,summary.status,summary.impact])row.append(node('td',value));const cell=node('td');cell.append(action('查看事故',()=>showIncident(item.id)));row.append(cell);body.append(row); }
    table.append(head,body);const scroll=node('div');scroll.className='admin-table-scroll';scroll.append(table);incidents.append(scroll,node('p',`第 ${incidentPage+1} 页${list.value.total!==undefined?' · 共 '+list.value.total+' 起事故':''}`));
    if(incidentPage>0)incidents.append(action('上一页事故',()=>loadIncidents(incidentPages[incidentPage-1],{page:incidentPage-1})));
    if(list.value.next_cursor) incidents.append(action('下一页事故',()=>loadIncidents(list.value.next_cursor,{page:incidentPage+1,pages:[...incidentPages.slice(0,incidentPage+1),list.value.next_cursor]})));
    return status.status==='fulfilled'&&diagnostic.status==='fulfilled';
  }
  async function showIncident(id) {
    if (disposed) return;
    if(!incidentModal)incidentModal=detailDialog('事故详情',incidentDetail,{onClose:()=>{incidentModal=null;selectedIncident=undefined;++incidentSelection;}});
    const selection=++incidentSelection; selectedIncident=id;
    try {
      const item=await api.getWalletIncident(id); if(selection!==incidentSelection) return;
      const summary=incidentSummary(item,reservePolicy);
      incidentDetail.replaceChildren(node('h4',summary.title),...refreshAction('刷新此事故',()=>showIncident(id)));
      incidentDetail.append(node('p',summary.explanation));
      describe(incidentDetail,[['首次发生',incidentTime(item.opened_at)],['处理状态',summary.status],['影响范围',summary.impact],['最近异常记录',summary.condition]]);
      incidentDetail.append(node('p','首次发生时间描述历史记录，不代表当前仍然故障。历史详细原因未记录时，不能据当前结果推断。'));
      const related=node('section');related.append(node('h4','关联交易与用户'));for(const record of item.related_records??[])related.append(node('p',`${record.kind}：${record.id}（${record.relation}）`));if(!item.related_records?.length)related.append(node('p','暂无可核验的直接关联记录；全局监控事故不推测用户归属。'));incidentDetail.append(related);
      const timeline=node('section');timeline.append(node('h4','处理时间线'));for(const event of item.timeline??[])timeline.append(node('p',`${incidentTime(event.created_at)} · ${event.action} · ${event.reason_code} · ${event.status??event.result}`));if(!item.timeline?.length)timeline.append(node('p','暂无已记录的处理事件'));if(item.timeline_has_more)timeline.append(node('p','当前展示最近200条处理事件；更早记录保留在审计系统。'));incidentDetail.append(timeline);
      const technical=node('details');technical.append(node('summary','技术详情与时间线'));
      describe(technical,[['事故编号',item.id],['技术代码',item.code],['级别',item.severity],['版本',item.version],['复核证据摘要',item.clearance_digest],['确认人',item.acknowledged_by],['结案人',item.resolved_by],['最近发现',incidentTime(item.last_seen_at)],['接手时间',incidentTime(item.acknowledged_at)],['异常消失时间',incidentTime(item.cleared_at)],['结案时间',incidentTime(item.resolved_at)]]);incidentDetail.append(technical);
      if(item.status==='RESOLVED'||summary.advisory)return;
      const incidentGuidance=walletAccess?'事故详情只读可查看；处理操作按需验证钱包写入权限，验证后须重新确认，系统不会自动处理。':authMode==='operation_password'?'查看和检查当前状态无需操作密码。下方密码用于授权事故处理与结案，一次输入即可完成。':'验证码模式每次只完成一个步骤。请等待下一组六位验证码，再点击同一按钮继续；不会自动复用验证码。';
      incidentDetail.append(node('p',summary.temporarySource?`${incidentGuidance}处理不会改变资金启停，是否暂停请以当前资金控制状态为准。`:walletAccess?`${incidentGuidance}处理不会恢复资金。`:authMode==='operation_password'?'查看和检查当前状态无需操作密码。下方密码用于授权事故处理与结案，一次输入即可完成；处理后资金仍暂停。':'验证码模式每次只完成一个步骤。请等待下一组六位验证码，再点击同一按钮继续；不会自动复用验证码。'));
      commandForm(incidentDetail,'incident-process','检查并处理事故',[checkbox('accept_incident',summary.temporarySource?'我确认处理这起事故；处理不会改变资金启停':'我确认处理这起事故；完成后可前往“资金启停”恢复资金'),...credentialFields()],async(values,state)=>{
        const credential=credentialPayload(values);
        delete values.operation_password;delete values.mfa_proof;
        const result=await processIncident({id,api,journal,credentials:credential,authMode:walletAccess?'operation_password':authMode,onProgress:message=>{state.textContent=message;},shouldStop:()=>disposed||selection!==incidentSelection});
        if(disposed||selection!==incidentSelection)return;
        const message=result.status==='resolved'&&incidentSummary(result.item,reservePolicy).temporarySource?'事故已结案。事故处理不会改变资金启停；请核对当前资金控制状态，需要新鲜链上证据的操作仍须独立核验。':walletAccess&&result.status==='resolved'?'事故已结案。请前往资金启停，核对并单独确认恢复资金。':result.status==='resolved'?'事故已结案。下一步：前往“资金启停”，勾选恢复确认并输入操作密码，点击“核验并恢复资金”。核验通过后才会启用资金。':result.status==='needs_credential'?'当前步骤已完成或状态已更新。请使用下一组验证码，再次确认并继续检查。':'实时检查仍有异常，处理已停止。请按当前诊断排查后重新检查。';
        await showIncident(id);await loadIncidents();await loadControl();
        if(!disposed&&selectedIncident===id)incidentDetail.append(node('p',message));
      });
    } catch (error) { if(disposed||selection!==incidentSelection)return;authFailure(error); if(selection===incidentSelection) return stale(incidentDetail,'事故详情读取失败。'); }
  }
  const control = node('section');control.className='wallet-surface';aside.append(control); let controlGeneration=0;
  async function loadControl() {
    if(disposed) return;
    const generation=++controlGeneration;
    for (const el of descendants(control)) if(el.type==='submit')el.disabled=true;
    try {
      const current=await api.getManualWalletControl(); if(disposed||generation!==controlGeneration) return;
      if(!Number.isSafeInteger(current.epoch)||current.epoch<0||! /^[a-f0-9]{64}$/.test(current.snapshot_digest)||!Array.isArray(current.restriction_scopes)||!Number.isSafeInteger(current.unresolved_incidents)) throw Error('Invalid control state');
      fundSummary.textContent=`资金${current.status==='PAUSED'?'已暂停':['ACTIVE','RUNNING'].includes(current.status)?'已启用':'状态待核实'} · ${current.unresolved_incidents?`${current.unresolved_incidents} 起事故阻止恢复`:'无未结阻断事故'} · 限制来源：${current.restriction_scopes.map(x=>x==='manual_tron'?'人工钱包风控':x).join('、')||'无'}`;
      control.replaceChildren(node('h4','资金启停'),...refreshAction('刷新资金控制状态',loadControl));
      describe(control,[['状态',({PAUSED:'已暂停',ACTIVE:'已启用',RUNNING:'运行中',UNAVAILABLE:'暂不可用'}[current.status]??'状态待核实')],['限制来源',current.restriction_scopes.map(x=>x==='manual_tron'?'人工钱包风控':x).join('、')||'无'],['未结阻断事故',current.unresolved_incidents]]);
      control.append(node('p','恢复会重新核验链上证据、储备、告警与限制来源。结案不等于恢复；来源不明或其他风控限制不能在此解除。'));
      if(current.status==='PAUSED'&&current.unresolved_incidents!==0) {
        const recovery=node('button','核验并恢复资金');recovery.type='button';recovery.className='admin-secondary wallet-critical-action';recovery.disabled=true;
        control.append(recovery,node('p',`存在 ${current.unresolved_incidents} 起未结事故。请在“监控与事故”中逐起选择“检查并处理事故”。全部阻断事故处理后，再单独核验恢复资金。`));
      }
      for(const [kind,label] of [['pause','暂停新资金操作'],['resume','核验并恢复资金']]) {
        if(kind==='pause'&&!['RUNNING','ACTIVE'].includes(current.status)||kind==='resume'&&(current.status!=='PAUSED'||current.unresolved_incidents!==0)) continue;
        const operation=`control:${kind}:${current.epoch}`;
        commandForm(control,`control-${kind}`,label,[kind==='resume'?checkbox('confirm_restore','我确认在核验通过后恢复资金操作'):checkbox('confirm_pause','我确认暂停新的资金操作'),...credentialFields()],async values=>{
          const saved=journal.pending(operation);
          const metadata=saved?.metadata??{expected_epoch:current.epoch,snapshot_digest:current.snapshot_digest,reason_code:kind==='resume'?'OWNER_CONTROL_RESUME':'OWNER_CONTROL_PAUSE'};
          try {
            await mutate(operation,metadata,options=>api.manualWalletControlAction(kind,{...metadata,...credentialPayload(values)},options));
          } catch(error) {
            if(error?.code==='MANUAL_CONTROL_SNAPSHOT_CONFLICT') {
              journal.finish(operation);
              if(!disposed) {
                await loadControl();
                control.append(node('p','控制状态已经变化，原请求未执行。请核对刷新后的状态，再次确认操作。'));
              }
              return;
            }
            throw error;
          }
          if(!disposed) await loadControl();
        },operation);
      }
    } catch(error) { if(disposed||generation!==controlGeneration)return;authFailure(error); if(!disposed&&generation===controlGeneration) {fundSummary.textContent='资金状态暂不可用，请刷新核实。';return stale(control,'资金控制状态不可用，不能据此判断已恢复。');} }
  }
  const handover=node('section'),history=node('details');history.className='wallet-surface wallet-history';history.append(node('summary','历史监控交接'),handover);primary.append(history);let handoverGeneration=0;
  function handoverForm(parent,name,label,run,extra=[],operation=name) {
    return commandForm(parent,name,label,[field('reason_code','交接原因代码',{pattern:'[A-Z][A-Z0-9_]{2,99}'}),...extra,...credentialFields()],run,operation);
  }
  function checkbox(name,label) {
    const input=field(name,label);input.type='checkbox';input.value='true';return input;
  }
  async function loadHandover() {
    if(disposed||!journal) return;
    const generation=++handoverGeneration;
    handover.replaceChildren(node('h4','旧监控交接'),node('p','仅用于首次人工钱包模式交接。保留旧事故、失败告警及暂停，不会直接启用资金。'));
    try {
      const active=journal.pending('handover:active');
      if(!active) {
        handoverForm(handover,'handover-prepare','生成交接清单',async values=>{
          const operation='handover-prepare', metadata={reason_code:values.reason_code};
          const entry=journal.begin(operation,metadata);
          const result=await api.prepareWalletHandover({...metadata,...credentialPayload(values)},{idempotencyKey:entry.key});
          journal.begin('handover:active',{preparation_id:result.id});journal.finish(operation);
          if(!disposed) await loadHandover();
        });return;
      }
      const current=await api.getWalletHandover(active.metadata.preparation_id);
      if(disposed||generation!==handoverGeneration) return;
      if(!/^[a-f0-9]{64}$/.test(current.manifest_digest)||!Number.isSafeInteger(current.alert_count)||!Number.isSafeInteger(current.incident_count)) throw Error('Invalid handover state');
      describe(handover,[['交接状态',current.status],['事故数量',current.incident_count],['历史告警数量',current.alert_count],['清单摘要',current.manifest_digest],['清单到期',formatBeijingTime(current.expires_at)]]);
      if(current.source_configuration_version) describe(handover,[['来源配置版本',current.source_configuration_version],['部署记录摘要',current.deployment_record_sha256]]);
      if(Array.isArray(current.incidents)) for(const incident of current.incidents) {
        describe(handover,[['历史事故',incident.id],['事件码',incident.code],['代次 / 版本',`${incident.generation} / ${incident.version}`]]);
      }
      handover.append(action('刷新交接状态',loadHandover));
      if(current.status==='HANDOVER_COMPLETE_FUNDS_PAUSED') {handover.append(node('p','交接完成，资金仍暂停。请使用独立资金恢复核验。'));return;}
      const expires=Date.parse(current.expires_at);
      if(!Number.isFinite(expires)) throw Error('Invalid expiry');
      if(['INVALID','EXPIRED'].includes(current.status)||expires<=Date.now()) {
        handover.append(node('p','清单已失效或到期；重新生成不会删除原通知和交接历史。'),action('重新生成交接清单',()=>{journal.finish('handover:active');void loadHandover();}));return;
      }
      const kind=current.status==='PREPARED'?'notify':current.status==='NOTICE_DELIVERED'?'confirm':null;
      if(!kind) {handover.append(node('p','正在等待汇总通知送达，请稍后刷新。'));return;}
      const extra=kind==='confirm'?[checkbox('no_unregistered_payments','确认没有未登记或未核清的人工付款'),checkbox('notice_received','确认已收到并核对交接汇总邮件')]:[];
      if(extra.length) handover.append(node('p','请逐项确认：没有未登记或未核清的人工付款；已收到并核对汇总邮件。'));
      const operation=`handover-${kind}:${current.id}`;
      handoverForm(handover,`handover-${kind}`,kind==='notify'?'发送一封交接汇总邮件':'确认交接并保留暂停',async values=>{
        const metadata={manifest_digest:current.manifest_digest,reason_code:values.reason_code,...(kind==='confirm'?{no_unregistered_payments:true,notice_received:true}:{})};
        let result;
        try {
          result=await mutate(operation,metadata,options=>api.walletHandoverAction(current.id,kind,{...metadata,...credentialPayload(values)},options));
        } catch(error) {
          if(['HANDOVER_MANIFEST_CONFLICT','HANDOVER_PREPARATION_EXPIRED'].includes(error?.code)) {
            journal.finish(operation);
            if(!disposed) {
              await loadHandover();
              handover.append(node('p','原交接请求未执行，清单已变化或过期。请重新生成并核对清单。'),action('重新生成交接清单',()=>{journal.finish('handover:active');void loadHandover();}));
            }
            return;
          }
          throw error;
        }
        if(disposed) return;
        if(result.status==='HANDOVER_COMPLETE_FUNDS_PAUSED') handover.replaceChildren(node('h4','旧监控交接'),node('p','交接完成，资金仍暂停。请刷新资金控制状态，再单独核验恢复。'));
        else await loadHandover();
      },extra,operation);
    } catch(error) {authFailure(error);if(!disposed&&generation===handoverGeneration) handover.append(node('p',`交接状态未确认：${error.code??'REQUEST_FAILED'}。请保留原请求并刷新。`),action('刷新交接状态',loadHandover));}
  }
  let ownRefresh,queuedRefresh,refreshDrafts,refreshInitialForms,accessCheckGeneration=0;
  const refreshStatus=node('p');refreshStatus.setAttribute('role','status');heading.append(refreshStatus);
  const check=action('检查当前状态',()=>root.refresh());
  heartbeat.append(node('p','检查当前状态无需操作密码，仅刷新当前状态，不会结案或恢复资金。'),check);
  root.suspendForAccessCheck = () => {
    if(disposed)return;
    ++accessCheckGeneration;
    const writeForms=new Set([...forms(),...(refreshInitialForms??[])].filter(form=>form.className==='admin-command-form'));
    ++detailGeneration;++incidentSelection;++ownerPreviewGeneration;
    payoutModal?.close();incidentModal?.close();ownerConfirmModal?.close();ownerConfirmModal=null;ownerPreviewed=null;ownerCandidate=null;ownerPendingQueried=false;
    for(const form of writeForms)for(const input of descendants(form)){
      if(input.tagName!=='INPUT'&&input.tag!=='input'&&input.tagName!=='SELECT'&&input.tag!=='select'&&
          input.tagName!=='TEXTAREA'&&input.tag!=='textarea')continue;
      if(input.type==='checkbox')input.checked=false;else input.value='';
    }
    for(const form of writeForms)refreshDrafts?.delete(form.name);
    for(const input of secretInputs)input.value='';
    if(ownerState)ownerState.textContent='钱包权限正在重新核验；旧预检和未提交草稿已清除。';
  };
  root.dispose = () => {
    disposed=true;++mfaGeneration;++listGeneration;++detailGeneration;++incidentGeneration;++incidentSelection;++controlGeneration;++handoverGeneration;++ownerPreviewGeneration;
    payoutModal?.close();incidentModal?.close();ownerConfirmModal?.close();ownerConfirmModal=null;ownerPreviewed=null;ownerCandidate=null;
    if(queuedRefresh){queuedRefresh.resolve(false);queuedRefresh=null;}
    for(const input of secretInputs)input.value='';secretInputs.clear();
  };
  root.refresh = async () => {
    if(disposed || refreshing) return false;
    if(writing) {
      refreshStatus.textContent='操作正在处理，完成后自动刷新，请稍候…';
      if(!queuedRefresh) { let resolve;const promise=new Promise(done=>resolve=done);queuedRefresh={promise,resolve}; }
      return queuedRefresh.promise;
    }
    refreshing=true;if(ownRefresh){ownRefresh.disabled=true;ownRefresh.setAttribute('aria-busy','true');}root.setAttribute('aria-busy','true');refreshStatus.textContent='正在刷新…';
    const selectionAtStart=[selectedOrder,selectedIncident];
    const accessAtStart=accessCheckGeneration;
    const initialForms=forms();
    const drafts=new Map(initialForms.map(form=>[form.name,inputsOf(form).map(input=>({name:input.name,value:input.value,checked:input.checked}))]));
    refreshInitialForms=initialForms;refreshDrafts=drafts;
    try {
      const securityResult=await loadSecurity();if(disposed)return false;
      if(securityOnly)return securityResult!==false;
      const results=await Promise.all([loadOrders(),loadIncidents(),loadControl(), selectedOrder ? showOrder(selectedOrder) : null, selectedIncident ? showIncident(selectedIncident) : null]);
      if(disposed)return false;
      for(const oldForm of initialForms){
        if(accessCheckGeneration!==accessAtStart&&oldForm.className==='admin-command-form'){drafts.delete(oldForm.name);continue;}
        drafts.set(oldForm.name,inputsOf(oldForm).map(input=>({name:input.name,value:input.value,checked:input.checked})));
      }
      if(selectedOrder!==selectionAtStart[0]){drafts.delete('claim');drafts.delete('txid');}
      if(selectedIncident!==selectionAtStart[1])for(const name of drafts.keys())if(name.startsWith('incident-'))drafts.delete(name);
      for(const form of forms()) {
        for(const draft of drafts.get(form.name)??[]) {
          const input=inputsOf(form).find(input=>input.name===draft.name); if(input){input.value=draft.value;input.checked=draft.checked;}
        }
        const original=initialForms.find(previous=>previous.name===form.name);
        const result=original&&descendants(original).find(el=>el.getAttribute?.('role')==='status'||el.role==='status');
        const current=descendants(form).find(el=>el.getAttribute?.('role')==='status'||el.role==='status');
        if(drafts.has(form.name)&&result?.textContent&&current)current.textContent=result.textContent;
      }
      const success=securityResult!==false&&results.every(result=>result!==false);
      refreshStatus.textContent=`${success?'已刷新':'部分数据刷新失败'} · ${formatBeijingTime(Date.now())}`;
      return success;
    } finally { drafts.clear();refreshDrafts=null;refreshInitialForms=null;refreshing=false;if(ownRefresh){ownRefresh.disabled=false;ownRefresh.setAttribute('aria-busy','false');}root.setAttribute('aria-busy','false'); }
  };
  if(!unifiedRefresh){const button=ownRefresh=action('↻',()=>root.refresh());button.className='admin-refresh';button.title='刷新';button.setAttribute('aria-label','刷新');heading.append(button);}
  if(securityOnly){workspace.replaceChildren(mfa);heading.hidden=true;}
  void loadSecurity().then(()=>{if(!disposed&&!securityOnly){void loadOrders();void loadIncidents();void loadControl();void loadHandover();}});
  return root;
}
import {formatBeijingTime} from './admin-formatters.js';
