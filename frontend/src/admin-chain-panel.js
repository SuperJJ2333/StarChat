import { formatBeijingTime, parseBeijingInput } from './admin-formatters.js';
import {detailDialog} from './admin-detail-dialog.js';
import {walletRepairDialog} from './admin-wallet-repair-dialog.js';

function node(tag, text, className) {
  const result = document.createElement(tag);
  if (text !== undefined) result.textContent = String(text);
  if (className) result.className = className;
  return result;
}

function time(value) {
  const formatted = formatBeijingTime(value);
  return formatted === '—' ? '暂无' : formatted;
}

function accounting(record) {
  const link = record.platform_record;
  if (!link) return "尚未核定";
  const labels = { CREDITED: "已入账", REVIEW: "待处理", SETTLED: "提现已结算" };
  const status = labels[link.ledger_status] ?? "尚未核定";
  return link.evidence_status === "CONFLICT" ? `${status}；证据冲突，需核查` : status;
}

function directionLabel(record) {
  if (record.direction === "INFLOW") return "转入";
  return record.platform_record?.kind === "PAYOUT" && record.platform_record.ledger_status === "SETTLED"
    ? "提现转出" : "未匹配转出";
}

export function chainPanel(api, {actorId}={}) {
  const panel = node("section", undefined, "admin-card admin-chain-panel");
  panel.append(node("h3", "官方钱包链上流水"), node("p",
    "TronGrid 单源监控。平台入账与提现结算以关联账本为准；待处理或证据冲突的流水需核查。", "admin-audit-note"));
  const summary = node("p", "正在读取监控状态…", "admin-audit-note");
  summary.setAttribute("role", "status");
  const form = node("form", undefined, "admin-filters");
  const direction = node("select", undefined, "admin-filter");
  direction.setAttribute("aria-label", "流水方向");
  for (const [value, label] of [["", "全部方向"], ["INFLOW", "转入"], ["UNMATCHED_OUTFLOW", "转出"]]) {
    const option = node("option", label); option.value = value; direction.append(option);
  }
  const txid = node("input", undefined, "admin-filter");
  txid.placeholder = "完整交易哈希"; txid.setAttribute("aria-label", "完整交易哈希");
  txid.pattern = "[a-fA-F0-9]{64}";
  const dates = ["开始时间", "结束时间"].map(label => {
    const input = node("input", undefined, "admin-filter");
    input.type = "datetime-local"; input.setAttribute("aria-label", label);
    input.title = "按北京时间输入（UTC+08:00）"; return input;
  });
  const submit = node("button", "查询 / 刷新", "admin-primary"); submit.type = "submit";
  form.append(direction, txid, ...dates, submit);
  const state = node("p", "正在加载流水…", "admin-audit-note"); state.setAttribute("role", "status");
  const rows = node("div"); rows.style.overflowX = "auto";
  const detail = node("section"); detail.setAttribute("aria-label", "流水详情"); detail.setAttribute("aria-live", "polite");
  const previous = node("button", "上一页", "admin-secondary"); previous.type = "button";
  const next = node("button", "下一页", "admin-secondary"); next.type = "button";
  const paging = node("div", undefined, "admin-filters"); paging.append(previous, next);
  panel.append(summary, form, state, rows, paging);
  let detailModal,repairModal;
  let offset = 0, snapshot, activeFilters = {}, generation = 0, detailGeneration = 0, selectedRecord, loading = false, disposed = false;
  const limit = 25;
  function staleDetail(message) {
    detail.replaceChildren(...Array.from(detail.children).filter(child=>child.className!=="admin-chain-stale"),
      node("p", `${message}；上次详情已过期，请刷新重试。`, "admin-chain-stale"));
  }
  async function showDetail(item, preserve = false) {
    if(disposed)return false;
    if(!detailModal)detailModal=detailDialog('流水详情',detail,{onClose:()=>{detailModal=null;selectedRecord=undefined;++detailGeneration;}});
    selectedRecord=item;
    const current = generation;
    const selected = ++detailGeneration;
    if(!preserve)detail.replaceChildren(node("p", "正在加载详情…"));
    try {
      const record = await api.getChainTransaction(item.txid, item.log_index);
      if (disposed || current !== generation || selected !== detailGeneration) return false;
      const list = node("dl");
      for (const [key, label] of [["txid", "交易哈希"], ["log_index", "日志索引"], ["block_number", "区块高度"],
        ["from_address", "转出地址"], ["to_address", "转入地址"], ["amount", "USDT 金额"]]) {
        list.append(node("dt", label), node("dd", record[key] ?? "暂无"));
      }
      const link = record.platform_record;
      if (link) {
        list.append(node('dt','用户归属说明'),node('dd',link.attribution_reason_text??(link.user_id?'已关联业务记录':'尚无通过核验的用户关联，请核查绑定及订单匹配原因')));
        if(link.user_username)list.append(node('dt','畅聊号'),node('dd',link.user_username),node('dt','用户名'),node('dd',link.user_nickname??'—'));
        for (const [key, label] of [["record_id", "关联收款 / 提现单"], ["user_id", "用户归属"],
          ["ledger_transaction_id", "账本交易编号"], ["intent_id", "充值意图编号"], ["reason_code", "核定原因码"]]) {
          list.append(node("dt", label), node("dd", link[key] ?? "尚未关联"));
        }
        const evidence = { VERIFIED: "已核验（TronGrid 单源）", UNVERIFIED: "尚未核验", CONFLICT: "证据冲突，需核查" };
        list.append(node("dt", "链上证据"), node("dd", evidence[link.evidence_status] ?? "尚未核验"));
      }
      list.style.overflowWrap = "anywhere";
      detail.replaceChildren(node("h4", "流水详情"), list, node("p", `平台处理：${accounting(record)}。`),node("p",`详情更新于 ${time(Date.now())}`));
      return true;
    } catch (error) { if (!disposed && current === generation && selected === detailGeneration) staleDetail(`详情读取失败：${error.message}`);return false; }
  }
  async function load({fresh = false, preserveSelection = false, requestedOffset = offset, filters = activeFilters} = {}) {
    if(disposed||loading)return false;
    const current = ++generation;loading=true;
    const priorPaging=[previous.disabled,next.disabled];
    previous.disabled = next.disabled = submit.disabled = true;
    state.textContent = "正在加载流水…";
    try {
      const [health, page] = await Promise.all([api.getChainSummary(), api.getChainTransactions({ ...filters, limit, offset:requestedOffset, snapshot:fresh?undefined:snapshot })]);
      if (disposed || current !== generation) return false;
      snapshot = page.snapshot;offset=requestedOffset;activeFilters=filters;
      summary.textContent = `链上余额：${health.balance ?? "暂无"} USDT；最近成功扫描：${time(health.last_success_ms)}；扫描水位：${time(health.checkpoint_ms)}；覆盖起点：${time(health.coverage_start_ms)}；观察器：${health.observer_status}；对账：${health.reconciliation}。`;
      state.textContent = page.total ? `共 ${page.total} 笔，显示 ${offset + 1}–${offset + page.items.length}。新流水请点击刷新。` : "当前筛选范围内暂无流水。";
      const table = node("table", undefined, "admin-table"), head = node("thead"), body = node("tbody"), headers = node("tr");
      for (const label of ["时间", "方向", "金额（USDT）", "交易哈希 / 日志", "入账核定", "操作"]) headers.append(node("th", label));
      head.append(headers);
      for (const item of page.items) {
        const tr = node("tr");
        for (const value of [time(item.timestamp_ms), directionLabel(item), item.amount, `${item.txid} / ${item.log_index}`, accounting(item)]) tr.append(node("td", value));
        const cell = node("td"), action = node("button", "详情", "admin-secondary"); action.type = "button";
        action.addEventListener("click", () => showDetail(item)); cell.append(action); tr.append(cell); body.append(tr);
        if(actorId){const repair=node('button',item.direction==='INFLOW'?'充值补入账':'提现核对','admin-secondary');repair.type='button';repair.addEventListener('click',()=>{repairModal?.close();repairModal=walletRepairDialog(api,item,{actorId,onClose:()=>{repairModal=null;}});});cell.append(repair);}
      }
      table.append(head, body); rows.replaceChildren(table);
      previous.disabled = offset === 0; next.disabled = offset + page.items.length >= page.total;
      if(preserveSelection&&selectedRecord)return await showDetail(selectedRecord,true);
      selectedRecord=undefined;detail.replaceChildren();
      return true;
    } catch (error) {
      if (disposed || current !== generation) return false;
      if(!rows.children.length)summary.textContent = "监控状态读取失败，不能据此判断钱包余额或扫描进度。";
      state.textContent = `流水加载失败：${error.message}。上次流水与监控状态已过期，请点击查询 / 刷新重试。`;
      if(selectedRecord)staleDetail("本轮刷新未完成");
      [previous.disabled,next.disabled]=priorPaging;
      return false;
    } finally { if (current === generation) {submit.disabled = false;loading=false;} }
  }
  form.addEventListener("submit", event => {
    event.preventDefault();
    const start = parseBeijingInput(dates[0].value);
    const end = parseBeijingInput(dates[1].value);
    if ([start, end].some(value => value !== undefined && !Number.isFinite(value))) {
      state.textContent = "请输入有效的北京时间。"; return;
    }
    if (start !== undefined && end !== undefined && start > end) { state.textContent = "开始时间不能晚于结束时间。"; return; }
    const filters = { direction: direction.value, txid: txid.value.trim(), start_ms: start, end_ms: end };
    void load({filters,requestedOffset:0,fresh:true});
  });
  previous.addEventListener("click", () => load({requestedOffset:Math.max(0,offset-limit)}));
  next.addEventListener("click", () => load({requestedOffset:offset+limit}));
  panel.refresh=()=>loading||disposed?Promise.resolve(false):load({fresh:true,preserveSelection:true});
  panel.dispose=()=>{disposed=true;++generation;++detailGeneration;detailModal?.close();repairModal?.close();};
  load();
  return panel;
}
