// Manual operations never sign or broadcast; API/ledger state is authoritative.
import {processIncident, incidentSummary, incidentError, incidentTime, diagnosticSummary, fundControlError} from './wallet-incident-workflow.js?v=20260910-readability';
import {detailDialog} from './admin-detail-dialog.js';
const SAFE_METADATA = new Set(['expected_digest', 'txid', 'reason_code', 'expected_version', 'clearance_digest', 'credential_id', 'expected_epoch', 'snapshot_digest','preparation_id','manifest_digest','no_unregistered_payments','notice_received']);
export function exactUsdt(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)\.[0-9]{6}$/.test(value)) throw new Error('金额格式异常，操作已关闭');
  return value;
}
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
const statusLabel = status => ({REQUESTED:'待领取', CLAIMED:'已领取 · 尚未结算', UNKNOWN:'结果未知 · 尚未结算', SETTLED:'已结算', CANCELLED:'已取消'}[status] ?? '状态未知');

export function manualWalletPanel(api, {actor, storage, clipboard = globalThis.navigator?.clipboard, onReauthenticate, unifiedRefresh = false, walletAccess = false, securityOnly = false, onSecurityChanged} = {}) {
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
  const forms = () => [...descendants(root), ...(incidentModal ? descendants(incidentDetail) : [])].filter(el => el.tagName === 'FORM' || el.tag === 'form');
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
  }
  let journal;
  try { journal = operationJournal(storage ?? globalThis.localStorage, actor?.id); } catch { root.append(node('p', '无法保存管理员请求恢复记录，写操作已关闭。')); }
  function commandForm(parent, name, label, inputs, run, operation) {
    for (const input of inputs) if (input.type === 'password') secretInputs.add(input);
    const form = node('form'); form.name = name; form.className = 'admin-command-form';
    const blocked=()=>!journal||authMode==='loading'||authMode==='unavailable'||authMode==='operation_password'&&!operationConfigured&&name!=='operation-password';
    const submit = node('button', label); submit.type = 'submit'; submit.className = 'admin-primary'; submit.disabled = blocked();
    const state = node('p'); state.setAttribute('role', 'status');
    if (journal && operation) {
      const pending = journal.pending(operation);
      if (pending) {
        for (const input of inputs) if (input.type !== 'password' && pending.metadata[input.name] !== undefined) input.value = pending.metadata[input.name];
        state.textContent = walletAccess?'已恢复未确认请求；请先刷新服务端状态，核对原参数后确认继续。':'已恢复未确认请求；请先刷新服务端状态，再输入验证凭证重试。';
      }
    }
    form.append(...inputs.map(input=>{
      const label=node('label');label.className=input.type==='checkbox'?'wallet-check':'wallet-field';
      const caption=node('span',input.getAttribute?.('aria-label')??input['aria-label']);
      label.append(...(input.type==='checkbox'?[input,caption]:[caption,input]));return label;
    }), submit, state); parent.append(form);
    form.addEventListener('submit', async event => {
      event.preventDefault(); if (disposed || refreshing || writing || reading || reauthenticating || submit.disabled || blocked()) return;
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
  const mfa = node('section'); mfa.className='wallet-surface wallet-security';mfa.setAttribute('aria-label','账户安全设置'); aside.append(mfa);
  let mfaGeneration = 0;
  async function loadSecurity() {
    if(!api.getWalletOperationSecurity) return loadMfa();
    const generation=++mfaGeneration;
    try {
      const current=await api.getWalletOperationSecurity();if(disposed||generation!==mfaGeneration)return;
      if(!['totp','operation_password'].includes(current.auth_mode)||typeof current.configured!=='boolean'||!Number.isSafeInteger(current.version)||current.version<0)throw Error('INVALID_SECURITY_STATE');
      authMode=current.auth_mode;operationConfigured=current.configured;
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
    }catch(error){if(disposed||generation!==mfaGeneration)return;authMode='unavailable';authFailure(error);if(!disposed&&generation===mfaGeneration)return stale(mfa,'安全设置暂不可用，敏感操作已关闭。');}
  }
  async function loadMfa() {
    if (disposed) return;
    const generation = ++mfaGeneration;
    try {
      const current = await api.getWalletMfaStatus(); if (disposed || generation !== mfaGeneration) return;authMode='totp';
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
  const listState = node('p'); listState.setAttribute('role','status');
  const queue=node('section');queue.className='wallet-surface wallet-queue';orders.className='wallet-orders';detail.className='wallet-detail';
  queue.append(node('h4','人工出款队列'),node('p','核对锁定信息，领取后在 imToken 完成签名。'),...refreshAction('刷新出款队列',()=>loadOrders()),listState,orders,detail);primary.append(queue);
  let listGeneration=0, detailGeneration=0;
  async function loadOrders(cursor = orderCursor) {
    if (disposed) return;
    const generation=++listGeneration; orderCursor=cursor; listState.textContent='正在加载出款…';
    try {
      const page=await api.getManualPayouts({limit:25,cursor}); if(generation!==listGeneration) return;
      orders.replaceChildren();
      listState.textContent=page.items.length?'金额均为 USDT，保留六位小数。':'暂无人工出款';
      for(const item of page.items) {
        const row=node('article'),summary=node('div');summary.className='wallet-order-summary';
        const status=node('span',statusLabel(item.status));status.className=item.status==='UNKNOWN'?'wallet-order-state is-unknown':'wallet-order-state';
        summary.append(node('p',item.id),node('strong',`${exactUsdt(item.amount)} USDT`),status);
        row.append(summary,action('查看出款',()=>showOrder(item.id))); orders.append(row);
      }
      if(page.next_cursor) orders.append(action('下一页出款',()=>loadOrders(page.next_cursor)));
    } catch (error) { if(disposed||generation!==listGeneration)return;authFailure(error); if(generation===listGeneration) { listState.textContent='出款加载失败，上次数据已过期，请刷新重试。'; return false; } }
  }
  async function showOrder(id) {
    if (disposed) return;
    const generation=++detailGeneration; selectedOrder=id;
    try {
      const item=await api.getManualPayout(id); if(generation!==detailGeneration) return;
      const s=item.snapshot;
      for(const name of ['amount','fee','hold','receive']) exactUsdt(s[name]);
      if(s.fee!=='0.000000'||s.amount!==item.amount||! /^[a-f0-9]{64}$/.test(item.digest)) throw new Error('Invalid snapshot');
      detail.replaceChildren(node('h4',`出款 ${item.id}`),node('p',statusLabel(item.status)),...refreshAction('刷新此出款',()=>showOrder(id)));
      describe(detail,[['收款地址（锁定）',s.target_address],['官方出款地址（锁定）',s.official_address],['网络',s.network],['合约',s.contract],['本金 USDT',s.amount],['服务费 USDT',s.fee],['总冻结 USDT',s.hold],['到账 USDT',s.receive],['不可变报价摘要',item.digest],['绑定版本',s.binding_version],['官方配置版本',s.official_config_version],['报价到期',formatBeijingTime(s.expires_at)],['领取管理员',item.claimed_by],['候选哈希',item.candidate_txid],['结算哈希',item.settlement_txid],['复核原因',item.review_reason]]);
      for(const candidate of item.candidates ?? []) describe(detail,[['候选历史',candidate.txid],['操作者',candidate.actor_id],['原因',candidate.reason_code],['时间',formatBeijingTime(candidate.created_at)]]);
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
        if (item.claimed_by !== actor.id) {
          detail.append(node('p','此订单未由当前管理员领取，仅可核查记录；不提供付款指令或哈希提交。'));
          return;
        }
        const copyState=node('p'); copyState.setAttribute('role','status');
        for(const [label,value] of [['复制收款地址',s.target_address],['复制精确金额',s.amount]]) detail.append(action(label,async()=>{
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
  let incidentModal;
  const incidentFilters=node('form');incidentFilters.name='monitoring-filters';incidentFilters.className='admin-filters';const incidentInputs={};
  for(const [key,label,values] of [['status','处理状态',[['','全部状态'],['OPEN','未处理'],['ACKNOWLEDGED','已确认'],['RESOLVED','已结案']]],['severity','事故等级',[['','全部等级'],['P0','P0'],['P1','P1']]],['sort','排序',[['opened_desc','发生时间：新到旧'],['opened_asc','发生时间：旧到新'],['updated_desc','最近发现：新到旧']]]]){const select=node('select');select.className='admin-filter';select.setAttribute('aria-label',label);for(const [value,text] of values){const option=node('option',text);option.value=value;select.append(option);}incidentInputs[key]=select;incidentFilters.append(select);}
  const incidentSearch=node('input');incidentSearch.className='admin-filter';incidentSearch.placeholder='事故代码';incidentSearch.setAttribute('aria-label','事故代码');incidentSearch.maxLength=100;incidentInputs.code=incidentSearch;incidentFilters.append(incidentSearch);
  let activeIncidentFilters={},incidentPages=[undefined],incidentPage=0;
  incidentFilters.append(action('查询',()=>loadIncidents(null,{filters:Object.fromEntries(Object.entries(incidentInputs).map(([k,v])=>[k,v.value])),page:0,pages:[null]})),action('重置',()=>loadIncidents(null,{filters:{},page:0,pages:[null],reset:true})));
  incidentFilters.addEventListener('submit',event=>event.preventDefault());
  const monitoring=node('section');monitoring.className='wallet-surface';monitoring.append(node('h4','监控与事故'),fundSummary,monitor,diagnostics,node('p','历史事故与当前检查分别展示。处理事故不会启用资金，恢复需要单独核验。'),...refreshAction('刷新监控和事故',()=>loadIncidents(null,{page:0,pages:[null]})),incidentFilters,incidents);primary.append(monitoring);
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
    incidents.replaceChildren();
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
      incidentDetail.append(node('p',walletAccess?'钱包身份已验证。确认后执行事故检查与处理；不会恢复资金。':authMode==='operation_password'?'查看和检查当前状态无需操作密码。下方密码用于授权事故处理与结案，一次输入即可完成；处理后资金仍暂停。':'验证码模式每次只完成一个步骤。请等待下一组六位验证码，再点击同一按钮继续；不会自动复用验证码。'));
      commandForm(incidentDetail,'incident-process','检查并处理事故',[checkbox('accept_incident','我确认处理这起事故；完成后可前往“资金启停”恢复资金'),...credentialFields()],async(values,state)=>{
        const credential=credentialPayload(values);
        delete values.operation_password;delete values.mfa_proof;
        const result=await processIncident({id,api,journal,credentials:credential,authMode:walletAccess?'operation_password':authMode,onProgress:message=>{state.textContent=message;},shouldStop:()=>disposed||selection!==incidentSelection});
        if(disposed||selection!==incidentSelection)return;
        const message=walletAccess&&result.status==='resolved'?'事故已结案。请前往资金启停，核对并单独确认恢复资金。':result.status==='resolved'?'事故已结案。下一步：前往“资金启停”，勾选恢复确认并输入操作密码，点击“核验并恢复资金”。核验通过后才会启用资金。':result.status==='needs_credential'?'当前步骤已完成或状态已更新。请使用下一组验证码，再次确认并继续检查。':'实时检查仍有异常，处理已停止。请按当前诊断排查后重新检查。';
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
        const recovery=node('button','核验并恢复资金');recovery.type='button';recovery.className='admin-secondary';recovery.disabled=true;
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
  let ownRefresh,queuedRefresh;
  const refreshStatus=node('p');refreshStatus.setAttribute('role','status');heading.append(refreshStatus);
  const check=action('检查当前状态',()=>root.refresh());
  monitoring.append(node('p','检查当前状态无需操作密码，仅刷新当前状态，不会结案或恢复资金。'),check);
  root.dispose = () => {
    disposed=true;++mfaGeneration;++listGeneration;++detailGeneration;++incidentGeneration;++incidentSelection;++controlGeneration;++handoverGeneration;
    incidentModal?.close();
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
    const initialForms=forms();
    const drafts=new Map(initialForms.map(form=>[form.name,inputsOf(form).map(input=>({name:input.name,value:input.value,checked:input.checked}))]));
    try {
      const securityResult=await loadSecurity();if(disposed)return false;
      if(securityOnly)return securityResult!==false;
      const results=await Promise.all([loadOrders(),loadIncidents(),loadControl(), selectedOrder ? showOrder(selectedOrder) : null, selectedIncident ? showIncident(selectedIncident) : null]);
      if(disposed)return false;
      for(const oldForm of initialForms) drafts.set(oldForm.name,inputsOf(oldForm).map(input=>({name:input.name,value:input.value,checked:input.checked})));
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
    } finally { drafts.clear(); refreshing=false;if(ownRefresh){ownRefresh.disabled=false;ownRefresh.setAttribute('aria-busy','false');}root.setAttribute('aria-busy','false'); }
  };
  if(!unifiedRefresh){const button=ownRefresh=action('↻',()=>root.refresh());button.className='admin-refresh';button.title='刷新';button.setAttribute('aria-label','刷新');heading.append(button);}
  if(securityOnly){workspace.replaceChildren(mfa);heading.hidden=true;}
  void loadSecurity().then(()=>{if(!disposed&&!securityOnly){void loadOrders();void loadIncidents();void loadControl();void loadHandover();}});
  return root;
}
import {formatBeijingTime} from './admin-formatters.js';
