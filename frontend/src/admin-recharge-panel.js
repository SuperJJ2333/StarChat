// ADR-0077 后台：人工充值案件 / 官方客服目录 / 汇率与储备三类数量。
// 纪律：前端不凭提交成功就展示已充值——登记状态只来自服务端权威回执。

function element(tag, className, textContent) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (textContent !== undefined && textContent !== null) node.textContent = String(textContent);
  return node;
}

function fieldRow(label, value) {
  const row = element("div", "recharge-field-row");
  row.append(element("span", "recharge-field-label", label), element("span", "recharge-field-value", value ?? "—"));
  return row;
}

export function rechargePanel(api, { onRefresh = async () => {} } = {}) {
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

  // ---------------------------------------------------------- 汇率与储备
  const fxSection = element("div", "recharge-section");
  fxSection.append(element("h3", null, "汇率参考与储备三类数量"));
  const fxBody = element("div", "recharge-fx");
  const refreshFx = async () => {
    fxBody.replaceChildren(element("p", "admin-audit-note", "加载中…"));
    let rate = null, valuation = null;
    try { rate = await api.getFxRate(); } catch { rate = null; }
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
  const loadCases = async () => {
    body.replaceChildren();
    let items = [];
    try { items = (await api.getRechargePending()).items ?? []; } catch (error) {
      body.insertRow().append(element("td", "admin-status-cell", "案件加载失败（需要财务权限）")); return;
    }
    if (!items.length) { body.insertRow().append(element("td", "admin-status-cell", "暂无待处理案件")); return; }
    for (const item of items) {
      const tr = body.insertRow();
      tr.append(element("td", null, item.id), element("td", null, item.user_id),
        element("td", null, `${item.amount_usdt} USDT`),
        element("td", null, item.fx_rate ? `${item.fx_rate}${item.fx_rate_stale ? "（过期参考）" : ""}` : "—"),
        element("td", null, item.evidence_txid ?? "—"),
        element("td", null, item.binding_state ? `${item.binding_state} / ${item.binding_adjustment_id ?? '—'}${item.binding_failure_reason ? ` / ${item.binding_failure_reason}` : ''}` : (item.status === "SUBMITTED" ? "待处理（未入账）" : item.status)));
      const actions = element("td", "admin-status-cell");
      const adjustmentInput = element("input");
      adjustmentInput.placeholder = "财务调整 ID";
      const rateInput = element('input');
      rateInput.placeholder = '最终结算率（选填，点钻/USDT）';
      rateInput.setAttribute('aria-label', rateInput.placeholder);
      const bindButton = element("button", "admin-button", "绑定调整");
      bindButton.addEventListener("click", async () => {
        if (!adjustmentInput.value.trim()) { panelAlert("请填写财务调整 ID（先经既有财务审批链提交）"); return; }
        const body = { adjustment_id: adjustmentInput.value.trim() };
        if (rateInput.value.trim()) body.final_rate = rateInput.value.trim();
        const ok = await settle(api.bindRechargeAdjustment(item.id, body,
          { idempotencyKey: `bind:${item.id}:${body.adjustment_id}${body.final_rate ? `:${body.final_rate}` : ''}` }));
        if (ok) { panelAlert("已绑定，尚未因此入账；财务执行完成后可恢复登记"); await settle(loadCases); }
      });
      const completeButton = element("button", "admin-button", "完成登记");
      completeButton.addEventListener("click", async () => {
        const result = await settle(api.completeRechargeBinding(item.id, { idempotencyKey: `register:${item.id}` }));
        if (result) {
          panelAlert(result.status === 'CREDITED' && result.binding_state === 'REGISTERED' ? '已入账并完成登记'
            : result.status === 'PENDING_APPROVAL' ? '财务调整尚未执行，案件未入账'
            : `尚未完成登记：${result.binding_state || result.status || '待核对'}`);
          await settle(loadCases); await settle(refreshFx);
        }
      });
      const rejectInput = element("input");
      rejectInput.placeholder = "拒绝原因";
      const rejectButton = element("button", "admin-button", "拒绝");
      rejectButton.addEventListener("click", async () => {
        if (!rejectInput.value.trim() || rejectInput.value.trim().length < 3) { panelAlert("拒绝必须填写原因（≥3 字符）"); return; }
        const ok = await settle(api.rejectRecharge(item.id, { reason: rejectInput.value.trim() }, { idempotencyKey: `reject:${item.id}` }));
        if (ok) await settle(loadCases);
      });
      actions.append(adjustmentInput, rateInput, bindButton, completeButton, rejectInput, rejectButton);
      tr.append(actions);
    }
  };
  const reloadButton = element("button", "admin-button", "刷新待处理案件");
  reloadButton.addEventListener("click", () => settle(loadCases));
  section.append(reloadButton, table);
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
      const retryButton = element("button", "admin-button", "只读核实·重新登记");
      retryButton.addEventListener("click", async () => {
        if (!item.id || retryButton.disabled) return;
        retryButton.disabled = releaseButton.disabled = true;
        const result = await settle(api.reviewRecharge(item.request_id, { action: "retry", binding_id:item.id },
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
        if (!item.id || releaseButton.disabled) return;
        retryButton.disabled = releaseButton.disabled = true;
        const ok = await settle(api.reviewRecharge(item.request_id,
          { action: "release", reason: releaseInput.value.trim(), binding_id:item.id },
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
