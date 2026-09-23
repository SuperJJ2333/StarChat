// ADR-0077 后台：人工充值案件 / 官方客服目录 / 汇率与储备三类数量。
// 纪律：前端不凭提交成功就展示已充值——登记状态只来自服务端权威回执。

function element(tag, className, textContent) {
  const node = document.createElement(tag);
  if (className) node.className = className.replace(/\badmin-button\b/g, "admin-secondary");
  else if (tag === "input") node.className = "admin-filter";
  if (textContent !== undefined && textContent !== null) node.textContent = String(textContent);
  return node;
}

function fieldRow(label, value) {
  const row = element("div", "recharge-field-row");
  row.append(element("span", "recharge-field-label", label), element("span", "recharge-field-value", value ?? "—"));
  return row;
}

// Asset arithmetic stays in decimal strings / integer micro-units.
function decimalMicros(value) {
  if (typeof value !== 'string' || !/^[0-9]{1,24}(?:\.[0-9]{1,6})?$/.test(value.trim())) return null;
  const [whole, fraction = ''] = value.trim().split('.');
  const units = BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, '0'));
  return units > 0n ? units : null;
}
function formatFixed(units, digits) {
  const scale = 10n ** BigInt(digits);
  return `${units / scale}.${String(units % scale).padStart(digits, '0')}`;
}
function previewPoints(amount, rate) {
  // Positive decimal HALF_UP, matching server settlement quantization.
  return formatFixed((amount * rate + 5000000000n) / 10000000000n, 2);
}

export function rechargePanel(api, { actor = {}, canReview = false, canApprove = false, onOpenPayout = null } = {}) {
  let disposed = false, casesGeneration = 0, filter = 'all';
  const claims = new Map(), busyOrders = new Set();
  let currentFx = null, fxRequest = null;
  const loadReference = () => {
    if (!fxRequest) fxRequest = Promise.resolve().then(()=>api.getFxRate())
      .catch(()=>null).finally(()=>{fxRequest=null;});
    return fxRequest;
  };
  const actorId = actor.id ?? actor.user_id;
  const key = prefix => `${prefix}:${globalThis.crypto.randomUUID()}`;
  const owned = item => !item.expires_at || Boolean(actorId && item.claimed_by === actorId && claims.has(item.id)
    && Date.parse(item.claim_expires_at) > Date.now());

  const panel = element("section", "admin-card admin-recharge-panel");
  const panelAlertNode = element("p", "admin-audit-note recharge-alert");
  function panelAlert(message) {
    panelAlertNode.textContent = message;
    panelAlertNode.hidden = false;
  }
  async function settle(operation) {
    try { return (await (typeof operation === 'function' ? operation() : operation)) ?? true; }
    catch(error) { panelAlert(`操作失败：${error?.message || '未知错误'}`); return false; }
  }
  panelAlertNode.hidden = true;
  panel.append(element("h2", null, "人工充值与结算"));
  panel.append(panelAlertNode);
  if (onOpenPayout) {
    const payout = element('button', 'admin-button', '打开提现订单工作台');
    payout.addEventListener('click', onOpenPayout); panel.append(payout);
  }

  // ---------------------------------------------------------- 汇率与储备
  const fxSection = element("div", "recharge-section");
  fxSection.append(element("h3", null, "汇率参考与储备三类数量"));
  const fxBody = element("div", "recharge-fx");
  const refreshFx = async () => {
    fxBody.replaceChildren(element("p", "admin-audit-note", "加载中…"));
    let rate = null, valuation = null;
    rate = await loadReference();
    try { valuation = await api.getReserveValuation(); } catch { valuation = null; }
    fxBody.replaceChildren();
    if (rate) {
      fxBody.append(
        fieldRow("USD/CNY 参考汇率", rate.rate),
        fieldRow("更新时刻", rate.fetched_at),
        fieldRow("状态", rate.stale ? "过期参考（不用于自动资金结算）" : "有效"),
        element("p", "admin-audit-note", rate.disclaimer || "参考估算，最终以客服结算为准"));
    } else {
      fxBody.append(element("p", "admin-audit-note", "汇率服务不可用"));
    }
    if (valuation) {
      fxBody.append(
        fieldRow("点钻账面数量（CAIBI face）", valuation.caibi_face),
        fieldRow("参考 USDT 估值", valuation.caibi_reference_usdt),
        fieldRow("实际 USDT 义务", valuation.usdt_obligation),
        fieldRow("估值汇率", valuation.valuation_rate),
        fieldRow("已批准未支付应付", valuation.approved_unpaid_usdt));
    }
  };
  const fxButton = element("button", "admin-button", "刷新汇率与储备");
  fxButton.addEventListener("click", () => settle(refreshFx()));
  fxSection.append(fxButton, fxBody);
  panel.append(fxSection);

  // ---------------------------------------------------------- 待处理案件
  const section = element("div", "recharge-section");
  section.append(element("h3", null, "待处理充值案件"));
  const table = element("table", "admin-table recharge-cases");
  const head = table.createTHead().insertRow();
  ["申请单", "用户", "原始金额（USDT）", "参考汇率", "凭证", "绑定状态", "操作"].forEach((h) => head.append(element("th", null, h)));
  const body = table.createTBody();
  let nextCasesCursor=null, casesPageCursor=null;
  const nextCases=element('button','admin-button','下一页充值案件');nextCases.disabled=true;
  nextCases.addEventListener('click',()=>{if(!nextCases.disabled)void loadCases(true);});
  let currentItems = [];
  const renderCases = () => {
    body.replaceChildren();
    const items = currentItems.filter(item => filter !== 'mine' || item.claimed_by === actorId);
    if (!items.length) { body.insertRow().append(element('td', 'admin-status-cell', '暂无待处理案件')); return; }
    for (const item of items) {
      const tr = body.insertRow();
      tr.append(element('td', null, item.id), element('td', null, item.user_id),
        element('td', null, `${item.amount_usdt} USDT`),
        element('td', null, item.fx_rate ? `${item.fx_rate}${item.fx_rate_stale ? '（过期参考）' : '（参考）'}` : '—'),
        element('td', null, item.evidence_txid ?? '—'),
        element('td', null, `${item.processing_stage ?? item.status} / ${item.binding_state ?? '未绑定'}`));
      const actions = element('td', 'admin-status-cell'); tr.append(actions);
      actions.append(element('p','admin-audit-note', `实际到账 ${item.actual_received_usdt ?? '待核验'} USDT · 最终点钻 ${item.final_caibi_amount ?? item.binding_final_caibi_amount ?? '待结算'}`));
      if (item.expires_at) actions.append(element('p','admin-audit-note', `处理截止（北京）：${new Date(item.expires_at).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}`));
      const command = async operation => {
        if (disposed || busyOrders.has(item.id) || !owned(item)) return;
        busyOrders.add(item.id); renderCases();
        try { const result = await operation(claims.get(item.id));
          if (!disposed) { panelAlert(result.status === 'CREDITED' && result.binding_state === 'REGISTERED' ? '已入账并完成登记'
            : result.status === 'PENDING_APPROVAL' ? '财务调整尚未执行，案件未入账' : '服务端已受理，请按权威状态继续处理；尚未因此入账'); }
        } catch(error) {
          if(error.code==='PENDING_APPROVAL')panelAlert('等待独立管理员审批，尚未入账；审批通过后再执行结算。');
          else {claims.delete(item.id); panelAlert(`操作未确认，已停止修改，请刷新并重新认领：${error.message ?? '认领已失效'}`);}
        } finally { busyOrders.delete(item.id); if (!disposed) await loadCases(); }
      };
      const addButton = (label, run, disabled = false) => {
        const button = element('button','admin-button',label);button.disabled = disabled || busyOrders.has(item.id);
        button.addEventListener('click',()=>{if(!button.disabled)void run();});actions.append(button);return button;
      };
      if(canApprove && item.binding_adjustment_id && item.settlement_submitted_by && item.settlement_submitted_by!==actorId
          && ['SUBMITTED','FINANCE_APPROVED'].includes(item.settlement_status)){
        actions.append(element('p','admin-audit-note',`独立审批：${item.binding_final_caibi_amount??'—'} 点钻 · 汇率 ${item.binding_final_rate??'—'} · 提交人 ${item.settlement_submitted_by}`));
        const review=async(approve,finance=false)=>{
          if(disposed||busyOrders.has(item.id))return;busyOrders.add(item.id);renderCases();
          try{const result=await (finance?api.financeReviewAdjustment:api.adminReviewAdjustment)(item.binding_adjustment_id,{approve},{idempotencyKey:key(`approval:${item.binding_adjustment_id}`)});
            if(!disposed)panelAlert(`审批结果：${result.status??'已受理'}；资金由持有人在审批后执行，不会自动入账。`);
          }catch(error){if(!disposed)panelAlert(`审批失败：${error.message??'请刷新重试'}`);}
          finally{busyOrders.delete(item.id);if(!disposed)await loadCases();}
        };
        if(item.settlement_status==='SUBMITTED')addButton('独立财务审核通过',()=>review(true,true));
        addButton('独立管理员批准结算',()=>review(true));
        addButton('独立管理员拒绝结算',()=>review(false));
      }
      const activeOther = item.claimed_by && item.claimed_by !== actorId && Date.parse(item.claim_expires_at) > Date.now();
      if (!owned(item)) {
        const needsReview=item.processing_stage==='NEEDS_REVIEW' || (item.expires_at && Date.parse(item.expires_at)<=Date.now());
        const reviewReason=element('input');reviewReason.placeholder='核对受理原因（至少3字符）';reviewReason.setAttribute('aria-label',reviewReason.placeholder);
        actions.append(element('span',null,activeOther ? '其他客服处理中（只读）' : '请先认领，服务端将校验受理期限'));
        if(needsReview && !canReview)actions.append(element('p','admin-audit-note','已转待核对，需要财务复核权限受理。'));
        if(needsReview && canReview && !activeOther)actions.append(reviewReason);
        if (!activeOther && actorId && (!needsReview || canReview)) addButton(needsReview?'认领待核对案件':'认领案件',async()=>{
          if(needsReview && reviewReason.value.trim().length<3){panelAlert('请填写核对受理原因（至少3字符）');return;}
          if(disposed || busyOrders.has(item.id))return;busyOrders.add(item.id);renderCases();
          try {const result=await api.claimRecharge(item.id,{idempotencyKey:key(`claim:${item.id}`)},needsReview?{review:true,reason:reviewReason.value.trim()}:{});
            if(!disposed && result.claim_token && result.claimed_by===actorId)claims.set(item.id,result.claim_token);
          }catch(error){claims.delete(item.id);panelAlert(`认领失败：${error.message ?? '案件已被认领'}`);}
          finally{busyOrders.delete(item.id);if(!disposed){await loadCases();await loadReview();}}
        });
        continue;
      }
      if(item.expires_at && canReview && item.processing_stage==='NEEDS_REVIEW'){
      actions.append(element('p','admin-audit-note','辅助人工核查：仅用于待核对案件；仍由服务端核验链上证据。'));
      const txid = element('input');txid.placeholder='到账交易哈希';txid.value=item.evidence_txid ?? '';txid.setAttribute('aria-label',txid.placeholder);
      const logIndex = element('input');logIndex.placeholder='链上日志序号';logIndex.value='0';logIndex.setAttribute('aria-label',logIndex.placeholder);
      actions.append(txid,logIndex);
      addButton('核验实际到账',()=>{
        if(!txid.value.trim() || !/^\d+$/.test(logIndex.value) || !Number.isSafeInteger(Number(logIndex.value))){panelAlert('请填写交易哈希与有效日志序号');return;}
        return command(claim_token=>api.verifyRechargePayment(item.id,{claim_token,txid:txid.value.trim(),log_index:Number(logIndex.value)},{idempotencyKey:key(`verify:${item.id}`)}));
      });
      }
      if(item.payment_verified || !item.expires_at){
        if(item.expires_at){
          const reference = decimalMicros(currentFx?.rate);
          const baseRate = currentFx?.stale === false && Number.isFinite(Date.parse(currentFx?.fetched_at)) ? reference : null;
          const received = decimalMicros(item.actual_received_usdt);
          actions.append(element('p','admin-audit-note', baseRate
            ? `本次参考基准：${formatFixed(baseRate,6)} 点钻/USDT`
            : `基准不可用${currentFx?.stale ? '（过期参考）' : ''}；请核对汇率后明确填写最终结算率`));
          if(Number.isFinite(Date.parse(currentFx?.fetched_at)))actions.append(element('p','admin-audit-note',`参考获取时间（北京）：${new Date(currentFx.fetched_at).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai'})}`));
          const rate=element('input');rate.placeholder='最终结算率（点钻/USDT）';rate.setAttribute('aria-label',rate.placeholder);
          rate.value=baseRate ? formatFixed(baseRate,6) : '';actions.append(rate);
          const preview=element('p','admin-audit-note');
          const updatePreview=()=>{
            const finalRate=decimalMicros(rate.value);
            preview.textContent=received && finalRate
              ? `最终点钻预览：${previewPoints(received,finalRate)}（实际到账 ${item.actual_received_usdt} USDT × 最终结算率 ${formatFixed(finalRate,6)}）`
              : '最终点钻预览：待填写有效结算率并确认实际到账金额';
          };
          rate.addEventListener('input',updatePreview);
          for(const [label,percent] of [['-5%',95n],['-1%',99n],['基准',100n],['+1%',101n],['+5%',105n]]){
            addButton(label,()=>{if(baseRate){rate.value=formatFixed((baseRate*percent+50n)/100n,6);updatePreview();}},!baseRate);
          }
          actions.append(preview,element('p','admin-audit-note','参考汇率仅作结算基准，最终以客服确认的结算率和独立审批结果为准；预览不代表已入账。'));
          updatePreview();
          addButton('提交结算审批',()=>{
            if(!received || !decimalMicros(rate.value)){panelAlert('请确认实际到账金额并填写有效最终结算率（最多6位小数）');return;}
            return command(claim_token=>api.prepareRechargeSettlement(item.id,{claim_token,final_rate:rate.value.trim()},{idempotencyKey:`prepare:${item.id}:${rate.value.trim()}`}));
          },!received);
          if(item.binding_adjustment_id || item.adjustment_id){
            actions.append(element('p','admin-audit-note',`审批调整 ${item.binding_adjustment_id ?? item.adjustment_id}；需独立管理员审批后执行。`));
            addButton('审批后执行结算',()=>command(claim_token=>api.executeRechargeSettlement(item.id,{claim_token},{idempotencyKey:`execute:${item.id}:${item.binding_adjustment_id ?? item.adjustment_id}`})));
          }
        } else {
        const adjustment=element('input');adjustment.placeholder='财务调整 ID';adjustment.setAttribute('aria-label',adjustment.placeholder);
        const rate=element('input');rate.placeholder='最终结算率（点钻/USDT）';rate.setAttribute('aria-label',rate.placeholder);
        actions.append(adjustment,rate);
        addButton('绑定调整',()=>{
          if(!adjustment.value.trim() || !/^[0-9]+(?:\.[0-9]+)?$/.test(rate.value.trim())){panelAlert('请填写既有审批链财务调整 ID 和最终结算率');return;}
          return command(()=>api.bindRechargeAdjustment(item.id,{adjustment_id:adjustment.value.trim(),final_rate:rate.value.trim()},{idempotencyKey:`bind:${item.id}:${adjustment.value.trim()}:${rate.value.trim()}`}));
        });
        addButton('完成登记',()=>command(claim_token=>api.completeRechargeBinding(item.id,{idempotencyKey:`register:${item.id}`},{claim_token})));
        }
      } else actions.append(element('p','admin-audit-note','等待系统确认到账：自动匹配用户在 APP 绑定的钱包付款，确认前不可提交结算；无需用户或客服填写凭证。'));
      const reason=element('input');reason.placeholder='拒绝原因';reason.setAttribute('aria-label',reason.placeholder);actions.append(reason);
      addButton('拒绝',()=>{
        if(reason.value.trim().length<3){panelAlert('拒绝必须填写原因（≥3 字符）');return;}
        return command(claim_token=>api.rejectRecharge(item.id,{...item.expires_at?{claim_token}:{},reason:reason.value.trim()},{idempotencyKey:`reject:${item.id}`}));
      });
    }
  };
  const loadCases = async (nextPage=false) => {
    if(nextPage){if(nextCases.disabled)return;casesPageCursor=nextCasesCursor;}
    nextCases.disabled=true;
    const generation = ++casesGeneration;
    try {
      const [page, snapshot] = await Promise.all([api.getRechargePending({...casesPageCursor?{cursor:casesPageCursor}:{},limit:50}), loadReference()]);
      if(disposed || generation!==casesGeneration)return;
      currentFx=snapshot;
      nextCasesCursor=page.next_cursor??null;nextCases.disabled=!nextCasesCursor;
      currentItems=page.items??[];
      for(const id of claims.keys())if(!currentItems.some(item=>item.id===id && item.claimed_by===actorId && Date.parse(item.claim_expires_at)>Date.now()))claims.delete(id);
      renderCases();
    } catch(error) {
      if(disposed || generation!==casesGeneration)return;
      claims.clear();currentItems=[];body.replaceChildren();
      body.insertRow().append(element('td','admin-status-cell','案件加载失败，请检查权限或网络；修改已停止'));
    }
  };
  const tabs=element('div','admin-command-form');
  for(const [value,label] of [['all','公共充值队列'],['mine','我的处理中']]){
    const tab=element('button','admin-button',label);tab.addEventListener('click',()=>{filter=value;renderCases();});tabs.append(tab);
  }
  section.append(tabs);
  const heartbeat = async () => {
    if(disposed || document.hidden)return;
    let lost = false;
    for(const item of currentItems){
      if(!item.expires_at||!owned(item)||busyOrders.has(item.id))continue;
      try{const result=await api.heartbeatRecharge(item.id,{claim_token:claims.get(item.id)},{idempotencyKey:key(`heartbeat:${item.id}`)});
        if(!disposed && claims.has(item.id))Object.assign(item,result);
      }catch(error){lost=true;claims.delete(item.id);panelAlert('认领续租未确认，已停止修改，请刷新并重新认领');}
    }
    if(!disposed && lost){renderCases();await loadReview();}
  };
  const leaseTimer=setInterval(()=>void heartbeat(),60000);leaseTimer.unref?.();
  const resume=()=>{if(!document.hidden)void loadCases();};document.addEventListener?.('visibilitychange',resume);
  panel.heartbeat=heartbeat;
  panel.refreshOrders=async()=>{await loadCases();if(!disposed)await loadReview();};
  panel.dispose=()=>{disposed=true;++casesGeneration;claims.clear();clearInterval(leaseTimer);document.removeEventListener?.('visibilitychange',resume);};
  const reloadButton = element("button", "admin-button", "刷新待处理案件");
  reloadButton.addEventListener("click", () => {casesPageCursor=null;return settle(loadCases);});
  const tableScroll=element("div","admin-table-scroll");tableScroll.append(table);
  section.append(reloadButton, tableScroll, nextCases);
  panel.append(section);

  // ---------------------------------------------------------- 待核对队列
  const reviewSection = element("div", "recharge-section");
  reviewSection.append(element("h3", null, "待核对队列（不确定登记，继续占用绑定）"));
  const reviewTable = element("table", "admin-table recharge-review");
  const rHead = reviewTable.createTHead().insertRow();
  ["案件", "状态", "失败原因", "操作"].forEach((h) => rHead.append(element("th", null, h)));
  const rBody = reviewTable.createTBody();
  let reviewCursor = null, reviewGeneration = 0;
  const loadReview = async (reset = true) => {
    if (!reset && moreReviewButton.disabled) return;
    const generation = ++reviewGeneration;
    if (reset) reviewCursor = null;
    moreReviewButton.disabled = true;
    rBody.replaceChildren();
    let items = [];
    try {
      const page = await api.getRechargeReviewQueue(reviewCursor ? {cursor:reviewCursor,limit:20} : {limit:20});
      if (generation !== reviewGeneration) return;
      items = page.items ?? [];
      reviewCursor = page.next_cursor ?? null;
      moreReviewButton.disabled = !reviewCursor;
    } catch {
      if (generation !== reviewGeneration) return;
      rBody.insertRow().append(element('td','admin-status-cell','待核对队列加载失败，请检查权限或网络后重试'));
      return;
    }
    if (!items.length) { rBody.insertRow().append(element("td", "admin-status-cell", "无待核对绑定")); return; }
    for (const item of items) {
      const tr = rBody.insertRow();
      tr.append(element("td", null, item.request_id), element("td", null, item.request_status ?? "—"),
        element("td", null, item.failure_reason ?? "—"));
      const actions = element("td", "admin-status-cell");
      const managed=item.expires_at != null;
      const reviewOwned=()=>!managed || owned(currentItems.find(order=>order.id===item.request_id)??{id:item.request_id,...item});
      if(managed && !reviewOwned()){
        actions.append(element('span',null,'只读：请先在公共队列认领待核对案件'));tr.append(actions);continue;
      }
      const retryButton = element("button", "admin-button", "只读核实·重新登记");
      retryButton.addEventListener("click", async () => {
        if (!item.id || retryButton.disabled || !reviewOwned()) return;
        retryButton.disabled = releaseButton.disabled = true;
        const result = await settle(api.reviewRecharge(item.request_id, { action: "retry", binding_id:item.id,...managed?{claim_token:claims.get(item.request_id)}:{} },
          { idempotencyKey: `review-retry:${item.id}` }));
        if (result) {
          panelAlert(result.status === 'CREDITED' && result.binding_state === 'REGISTERED'
            ? '已入账并完成登记' : `尚未完成登记：${result.binding_state || result.status || '待核对'}`);
          await panel.refresh();
        }
        retryButton.disabled = releaseButton.disabled = false;
      });
      const releaseInput = element("input");
      releaseInput.placeholder = "释放原因（需确证未执行）";
      const releaseButton = element("button", "admin-button", "确证未执行·释放");
      releaseButton.addEventListener("click", async () => {
        if (!releaseInput.value.trim() || releaseInput.value.trim().length < 3) {
          panelAlert("释放必须填写原因；服务端会核证拒绝且未执行或已冲正，记录缺失不能证明未入账"); return;
        }
        if (!item.id || releaseButton.disabled || !reviewOwned()) return;
        retryButton.disabled = releaseButton.disabled = true;
        const ok = await settle(api.reviewRecharge(item.request_id,
          { action: "release", reason: releaseInput.value.trim(), binding_id:item.id,...managed?{claim_token:claims.get(item.request_id)}:{} },
          { idempotencyKey: `review-release:${item.id}` }));
        if (ok) { panelAlert('绑定已释放，案件未因此入账'); await panel.refresh(); }
        retryButton.disabled = releaseButton.disabled = false;
      });
      actions.append(retryButton, releaseInput, releaseButton);
      tr.append(actions);
    }
  };
  const reloadReviewButton = element("button", "admin-button", "刷新待核对队列");
  reloadReviewButton.addEventListener("click", () => settle(loadReview));
  const moreReviewButton = element('button','admin-button','下一页待核对');
  moreReviewButton.disabled = true;
  moreReviewButton.addEventListener('click',()=>settle(loadReview(false)));
  reviewSection.append(reloadReviewButton, reviewTable, moreReviewButton);
  panel.append(reviewSection);

  // ---------------------------------------------------------- 案件历史（分页）
  const historySection = element("div", "recharge-section");
  historySection.append(element("h3", null, "案件历史（含绑定状态）"));
  const historyTable = element("table", "admin-table recharge-history");
  const hHead = historyTable.createTHead().insertRow();
  ["申请单", "用户", "金额（USDT）", "案件状态", "绑定状态", "最终点钻"].forEach((h) => hHead.append(element("th", null, h)));
  const hBody = historyTable.createTBody();
  let historyCursor = null, historyGeneration = 0;
  const loadHistory = async (reset) => {
    if (!reset && moreButton.disabled) return;
    const generation = ++historyGeneration;
    if (reset) historyCursor = null;
    moreButton.disabled = true;
    try {
      const page = await api.listRechargeRequests(historyCursor ? { cursor: historyCursor, limit: 20 } : { limit: 20 });
      if (generation !== historyGeneration) return;
      hBody.replaceChildren();
      for (const item of page.items ?? []) {
        const tr = hBody.insertRow();
        tr.append(element("td", null, item.id), element("td", null, item.user_id),
          element("td", null, `${item.amount_usdt} USDT`), element("td", null, item.status),
          element("td", null, item.binding_state ?? "—"),
          element("td", null, item.final_caibi_amount ?? "—"));
      }
      historyCursor = page.next_cursor ?? null;
      moreButton.disabled = !historyCursor;
    } catch {
      if (generation !== historyGeneration) return;
      hBody.replaceChildren();
      hBody.insertRow().append(element("td", "admin-status-cell", "案件历史加载失败（需要财务权限）"));
      moreButton.disabled = true;
    }
  };
  const moreButton = element("button", "admin-button", "加载下一页");
  moreButton.disabled = true;
  moreButton.addEventListener("click", () => settle(loadHistory(false)));
  const reloadHistoryButton = element("button", "admin-button", "刷新案件历史");
  reloadHistoryButton.addEventListener("click", () => settle(loadHistory(true)));
  historySection.append(reloadHistoryButton, historyTable, moreButton);
  panel.append(historySection);

  // ---------------------------------------------------------- 审计时间线详情
  const timelineSection = element("div", "recharge-section");
  timelineSection.append(element("h3", null, "案件审计时间线"));
  const timelineInput = element("input");
  timelineInput.placeholder = "案件 ID";
  const timelineButton = element("button", "admin-button", "查看时间线");
  const timelineBody = element("pre", "admin-audit-note recharge-timeline");
  let timelineGeneration = 0;
  timelineButton.addEventListener("click", async () => {
    const requestId = timelineInput.value.trim();
    if (!requestId) { panelAlert("请填写案件 ID"); return; }
    const generation = ++timelineGeneration;
    timelineBody.textContent = "加载中…";
    try {
      const data = await api.getRechargeTimeline(requestId);
      if (generation !== timelineGeneration) return;
      timelineBody.textContent = JSON.stringify({ request_id: data.request_id ?? requestId, status: data.status, items: data.items }, null, 2);
    } catch (error) {
      if (generation !== timelineGeneration) return;
      timelineBody.textContent = "时间线加载失败：" + (error?.message || "无权限或案件不存在");
    }
  });
  timelineSection.append(timelineInput, timelineButton, timelineBody);
  panel.append(timelineSection);

  // ---------------------------------------------------------- 转让意图（查询与复核）
  const transferSection = element("div", "recharge-section");
  transferSection.append(element("h3", null, "群主转让意图（待核对处置）"));
  const roomInput = element("input");
  roomInput.placeholder = "房间 ID（!xxx:server）";
  const listIntentsButton = element("button", "admin-button", "查询意图");
  const intentTable = element("table", "admin-table transfer-intents");
  const iHead = intentTable.createTHead().insertRow();
  ["意图", "旧群主", "新群主", "阶段", "错误", "操作"].forEach((h) => iHead.append(element("th", null, h)));
  const iBody = intentTable.createTBody();
  let intentsGeneration = 0;
  const reviewingIntents = new Set();
  const currentIntentButtons = new Map();
  const reviewIntent = async (intentId, action, buttons, generation) => {
    if (generation !== intentsGeneration || reviewingIntents.has(intentId)) return;
    reviewingIntents.add(intentId);
    buttons.forEach(button => { button.disabled = true; });
    try {
      const result = await api.reviewTransferIntent(intentId, { action },
          { idempotencyKey: "transfer-review:" + intentId + ":" + action });
      if (generation !== intentsGeneration) return;
      panelAlert("意图 " + intentId + " 复核回执：" + JSON.stringify({ stage: result.stage,
          last_error_code: result.last_error_code }));
      await loadIntents();
    } catch (error) {
      if (generation === intentsGeneration) panelAlert("复核被拒绝：" + (error?.message || "权威证据不足或无权限"));
    } finally {
      reviewingIntents.delete(intentId);
      [...buttons, ...(currentIntentButtons.get(intentId) ?? [])].forEach(button => { button.disabled = false; });
    }
  };
  const loadIntents = async () => {
    const roomId = roomInput.value.trim();
    if (!roomId) { panelAlert("请填写房间 ID"); return; }
    const generation = ++intentsGeneration;
    iBody.replaceChildren();
    currentIntentButtons.clear();
    let items = [];
    try { items = (await api.listTransferIntents(roomId)).items ?? []; }
    catch (error) {
      if (generation !== intentsGeneration) return;
      iBody.insertRow().append(element("td", "admin-status-cell", "意图查询失败：" + (error?.message || "需要群主或管理员"))); return;
    }
    if (generation !== intentsGeneration) return;
    if (!items.length) { iBody.insertRow().append(element("td", "admin-status-cell", "无转让意图")); return; }
    for (const item of items) {
      const tr = iBody.insertRow();
      tr.append(element("td", null, item.id), element("td", null, item.expected_old_owner_user_id),
        element("td", null, item.new_owner_user_id), element("td", null, item.stage),
        element("td", null, item.last_error_code ?? "—"));
      const actions = element("td", "admin-status-cell");
      if (item.stage === "NEEDS_REVIEW" || item.stage === "MATRIX_PENDING") {
        const confirmButton = element("button", "admin-button", "确认已应用");
        confirmButton.addEventListener("click", () => reviewIntent(item.id, "confirm_applied", [confirmButton, failButton], generation));
        const failButton = element("button", "admin-button", "确证未应用");
        failButton.addEventListener("click", () => reviewIntent(item.id, "fail_unapplied", [confirmButton, failButton], generation));
        currentIntentButtons.set(item.id, [confirmButton, failButton]);
        confirmButton.disabled = failButton.disabled = reviewingIntents.has(item.id);
        actions.append(confirmButton, failButton);
      } else {
        actions.append(element("span", null, "—"));
      }
      tr.append(actions);
    }
  };
  listIntentsButton.addEventListener("click", () => settle(loadIntents()));
  transferSection.append(roomInput, listIntentsButton, intentTable);
  panel.append(transferSection);

  // ---------------------------------------------------------- 客服目录
  const directorySection = element("div", "recharge-section");
  directorySection.append(element("h3", null, "官方充值客服目录"));
  const directoryTable = element("table", "admin-table recharge-directory");
  const dHead = directoryTable.createTHead().insertRow();
  ["条目 ID", "客服 ID", "展示名", "收款地址（USDT/TRC20）", "启用", "排序"].forEach((h) => dHead.append(element("th", null, h)));
  const dBody = directoryTable.createTBody();
  const loadDirectory = async () => {
    dBody.replaceChildren();
    let items = [];
    try { items = (await api.getRechargeDirectory()).items ?? []; } catch {
      dBody.insertRow().append(element('td', 'admin-status-cell', '目录加载失败，请检查管理权限并重试')); return;
    }
    if (!items.length) { dBody.insertRow().append(element("td", "admin-status-cell", "暂无客服目录条目")); return; }
    for (const item of items) {
      const tr = dBody.insertRow();
      tr.append(element('td', null, item.id), element("td", null, item.cs_user_id), element("td", null, item.display_name),
        element("td", null, item.payment_address), element("td", null, item.enabled ? "启用" : "停用"),
        element("td", null, String(item.sort)));
    }
  };
  const inputs = {
    cs_user_id: element("input"), display_name: element("input"),
    payment_address: element("input"), note: element("input"),
    sort: element("input"), entry_id: element("input"),
  };
  inputs.cs_user_id.placeholder = "客服业务 user_id";
  inputs.display_name.placeholder = "展示名";
  inputs.payment_address.placeholder = "USDT (TRC20) 收款地址";
  inputs.note.placeholder = "说明（选填）";
  inputs.sort.placeholder = "排序（数字）";
  inputs.entry_id.placeholder = "按 ID 修改（留空＝创建）";
  const enabledCheck = element("input");
  enabledCheck.type = "checkbox"; enabledCheck.checked = true;
  const upsertButton = element("button", "admin-button", "创建/修改目录条目");
  upsertButton.addEventListener("click", async () => {
    const payload = {
      cs_user_id: inputs.cs_user_id.value.trim(), display_name: inputs.display_name.value.trim(),
      payment_address: inputs.payment_address.value.trim(), note: inputs.note.value.trim() || null,
      enabled: enabledCheck.checked, sort: Number(inputs.sort.value.trim() || 0),
    };
    if (!payload.cs_user_id || !payload.display_name || !payload.payment_address) {
      panelAlert("客服 ID、展示名与收款地址为必填"); return;
    }
    if (inputs.entry_id.value.trim()) payload.entry_id = inputs.entry_id.value.trim();
    const ok = await settle(api.upsertRechargeDirectory(payload, { idempotencyKey: `dir:${payload.entry_id || "new"}:${payload.cs_user_id}` }));
    if (ok) await settle(loadDirectory);
  });
  const form = element("form", "admin-command-form recharge-directory-form");
  form.addEventListener("submit", (event) => event.preventDefault());
  Object.values(inputs).forEach((input) => form.append(input));
  const label = element("label", null, "启用");
  label.append(enabledCheck);
  form.append(label, upsertButton);
  const reloadDirectoryButton = element("button", "admin-button", "刷新目录");
  reloadDirectoryButton.addEventListener("click", () => settle(loadDirectory));
  directorySection.append(reloadDirectoryButton, directoryTable, form);
  panel.append(directorySection);

  panel.refresh = async () => { await Promise.allSettled([loadCases(), loadDirectory(), refreshFx(), loadReview(), loadHistory(true)]); };
  panel.loadTransferIntents = loadIntents;
  panel.refresh();
  return panel;
}
