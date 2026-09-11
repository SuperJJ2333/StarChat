import { walletBindingDemo } from "./wallet-binding.js";
import { fixtures } from "../catalog/fixtures.js";
import { button, element } from "../components/base.js";
import { icon } from "../icons/icons.js";
import { component, createDeviceScreen, navigation, pageRoot } from "./shared.js";

function field(label, value, placeholder) {
  const wrapper = element("label", "c-finance-field");
  wrapper.append(element("span", "c-finance-field__label", label));
  const input = element("input", "c-finance-field__input");
  input.value = value;
  input.placeholder = placeholder;
  wrapper.append(input);
  return wrapper;
}

function historyRows(asset) {
  return [
    component("app-transaction-row", { kind: "wallet", title: asset === "USDT" ? "充值" : "收到转账", subtitle: "今天 09:41 · 成功", amount: asset === "USDT" ? "+20.000000 USDT" : "+88.00 CAIBI", status: "success" }),
    component("app-transaction-row", { kind: "gift", title: asset === "USDT" ? "提现" : "发出红包", subtitle: "昨天 18:20 · 处理中", amount: asset === "USDT" ? "-10.000000 USDT" : "-20.00 CAIBI", status: "processing" })
  ];
}

const groupRedPacketFixture = Object.freeze({
  joinedMemberIds: Object.freeze(["me", "zhou-ran", "lin-xiao", "chen-mo", "xia-yu", "an-ning", "mu-chen", "yan-yu"])
});
const ledgerRows = Object.freeze([
  Object.freeze({ id: "5c50c3be-17d8-4d9f-93c7-3d4a7ca0cf01", kind: "红包", title: "收到群红包", subtitle: "2026-09-11 09:41 · 已完成", amount: "+18.88 点钻" }),
  Object.freeze({ id: "3c40c1aa-836b-4dae-8c49-cd73c2ebbc10", kind: "转账", title: "转账已收款", subtitle: "2026-09-10 18:20 · 已完成", amount: "+200.00 点钻" }),
  Object.freeze({ id: "eed4fc7e-708f-43fc-9e7d-9a7bf3b45f11", kind: "提现", title: "提现退回", subtitle: "2026-09-09 12:06 · 已退回", amount: "+88.00 点钻" }),
  Object.freeze({ id: "34b47208-a790-45bd-91dc-69b545405c75", kind: "充值", title: "点钻充值", subtitle: "2026-09-08 10:15 · 已完成", amount: "+500.00 点钻" }),
  Object.freeze({ id: "ca149b1f-2cd8-472c-9d67-1e04b9a95e46", kind: "其他", title: "系统调整", subtitle: "2026-09-07 16:45 · 已完成", amount: "+10.00 点钻" })
]);

function ledgerButton(label, action) {
  const value = button("c-ledger-filter__button", label, action);
  value.textContent = label;
  return value;
}

function ledgerCopyButton(action) {
  const copy = button("c-ledger-copy-button", "复制账单ID", action);
  copy.append(icon("copy", "c-ledger-copy-button__icon"));
  return copy;
}

function ledgerMatches(row, kind, startAt, endAt, query) {
  const date = row.subtitle.slice(0, 10);
  return (kind === "全部" || row.kind === kind) &&
    (!startAt || date >= startAt) && (!endAt || date <= endAt) &&
    (!query || `${row.id} ${row.kind} ${row.title}`.includes(query));
}

function copyBillIdControl(row, action) {
  const feedback = element("p", "c-ledger-page-note", "");
  const copy = ledgerCopyButton(action);
  copy.addEventListener("click", async event => {
    event.stopPropagation();
    try {
      if (!navigator.clipboard?.writeText) throw new Error("clipboard unavailable");
      await navigator.clipboard.writeText(row.id);
      feedback.textContent = "账单ID已复制";
    } catch {
      feedback.textContent = "无法访问剪贴板，请长按复制账单ID";
    }
  });
  return [copy, feedback];
}
function ledgerDetail(row, onBack) {
  const panel = element("section", "c-ledger-detail");
  const timing = row.kind === "转账"
    ? [["转账时间", "2026-09-10 18:05"], ["收款时间", "2026-09-10 18:20"]]
    : [["入账时间", row.subtitle.slice(0, 16)]];
  const status = row.subtitle.split(" · ").at(-1);
  for (const [label, value] of [["金额", row.amount], ["状态", status], ["类型", row.kind], ["说明", row.title], ...timing, ["账单ID", row.id]]) {
    panel.append(element("dt", "c-ledger-detail__label", label), element("dd", "c-ledger-detail__value", value));
  }
  panel.append(...copyBillIdControl(row, "ledger:copy"));
  const back = ledgerButton("返回全部账单", "ledger:back");
  back.addEventListener("click", onBack);
  panel.append(back);
  return panel;
}
function ledger(definition) {
  const root = pageRoot(definition);
  const header = navigation("全部账单", { leading: "返回" });
  root.append(header);
  const content = element("div", "p-finance__content");
  const filters = element("form", "c-ledger-filter");
  const kind = element("select", "c-ledger-filter__control");
  kind.setAttribute("aria-label", "流水类型");
  for (const label of ["全部", "红包", "转账", "提现", "充值", "其他"]) {
    const option = element("option", null, label);
    option.value = label;
    option.selected = definition.state === "filtered" && label === "转账";
    kind.append(option);
  }
  const start = element("input", "c-ledger-filter__control");
  start.type = "date"; start.value = definition.state === "filtered" ? "2026-09-10" : ""; start.setAttribute("aria-label", "开始日期");
  const end = element("input", "c-ledger-filter__control");
  end.type = "date"; end.value = definition.state === "filtered" ? "2026-09-12" : ""; end.setAttribute("aria-label", "结束日期（包含当天）");
  const query = element("input", "c-ledger-filter__control");
  query.type = "search"; query.value = definition.state === "filtered" || definition.state === "search" ? "周然" : ""; query.placeholder = "搜索说明或业务编号"; query.setAttribute("aria-label", "账单搜索");
  const apply = ledgerButton("筛选", "ledger:apply");
  filters.append(kind, start, end, query, apply);
  content.append(filters);
  const results = element("section", "c-ledger-results");
  content.append(results);
  let page = definition.state === "paged" ? 2 : 1;
  let mode = definition.state;
  let selected = null;
  const pageSize = 2;
  const render = () => {
    results.replaceChildren();
    filters.hidden = selected !== null;
    header.setAttribute("title", selected ? "账单详情" : "全部账单");
    header.renderContract();
    if (selected) { results.append(ledgerDetail(selected, () => { selected = null; render(); })); return; }
    if (mode === "loading") { results.append(component("app-status-chip", { status: "processing", label: "正在加载账单…" })); return; }
    if (mode === "error") {
      const retry = ledgerButton("重试", "ledger:retry");
      retry.addEventListener("click", () => { mode = "all"; render(); });
      results.append(component("app-empty-state", { kind: "network", title: "账单加载失败", message: "请检查网络后重试" }), retry); return;
    }
    if (mode === "empty") {
      const reset = ledgerButton("重置筛选", "ledger:reset");
      reset.addEventListener("click", () => { kind.value = "全部"; start.value = ""; end.value = ""; query.value = ""; page = 1; mode = "all"; render(); });
      results.append(component("app-empty-state", { title: "暂无点钻流水", message: "调整日期、类型或关键词后重试" }), reset); return;
    }
    const matched = ledgerRows.filter(row => ledgerMatches(row, kind.value, start.value, end.value, query.value.trim()));
    if (!matched.length) {
      const reset = ledgerButton("重置筛选", "ledger:reset");
      reset.addEventListener("click", () => { kind.value = "全部"; start.value = ""; end.value = ""; query.value = ""; page = 1; mode = "all"; render(); });
      results.append(component("app-empty-state", { title: "暂无点钻流水", message: "调整日期、类型或关键词后重试" }), reset); return;
    }
    for (const row of matched.slice(0, page * pageSize)) {
      const item = button("c-ledger-row", `${row.title} ${row.amount}`, "ledger:detail");
      item.dataset.transactionId = row.id;
      item.append(element("span", "c-ledger-row__title", row.title), element("span", "c-ledger-row__subtitle", row.subtitle), element("strong", "c-ledger-row__amount", row.amount));
      item.addEventListener("click", () => { selected = row; render(); });
      results.append(item);
    }
    if (matched.length > page * pageSize) {
      const more = ledgerButton("加载更多", "ledger:more");
      more.addEventListener("click", () => { page += 1; render(); });
      results.append(more);
    }
  };
  const applyFilters = () => {
    if (start.value && end.value && start.value > end.value) {
      results.replaceChildren(component("app-toast", { kind: "error", message: "开始日期不能晚于结束日期" }));
      return;
    }
    page = 1; selected = null; mode = "all"; render();
  };
  filters.addEventListener("submit", event => { event.preventDefault(); applyFilters(); });
  apply.addEventListener("click", applyFilters);
  query.addEventListener("change", applyFilters);
  if (definition.state === "filtered" || definition.state === "search") { kind.value = "转账"; start.value = "2026-09-10"; end.value = "2026-09-12"; query.value = "转账"; }
  render();
  root.append(content);
  return root;
}

function transactionDetail(definition) {
  const root = pageRoot(definition);
  root.append(navigation("账单详情", { leading: "返回" }));
  const content = element("div", "p-finance__content");
  const bill = ledgerRows[1];
  content.append(
    component("app-status-chip", { status: "success", label: "已完成" }),
    component("app-amount-summary", { label: "实际入账", amount: "+200.00", asset: "点钻", hint: "转账本金 200.00 点钻 · 手续费由付款方承担" })
  );
  const details = element("dl", "c-ledger-detail");
  for (const [label, value] of [["金额", bill.amount], ["状态", "已完成"], ["类型", bill.kind], ["说明", "周然向你转账"], ["转账时间", "2026-09-10 18:05"], ["收款时间", "2026-09-10 18:20"], ["账单ID", bill.id]]) {
    details.append(element("dt", "c-ledger-detail__label", label), element("dd", "c-ledger-detail__value", value));
  }
  content.append(details, ...copyBillIdControl(bill, "ledger:copy-single"), ledgerButton("全部账单", "open:caibi-ledger-all"));
  root.append(content);
  return root;
}
function caibi(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "home" ? "点钻" : definition.page === "history" ? "点钻记录" : definition.page === "transaction" ? "账单详情" : definition.state === "receiver-accepted" ? "收款" : "点钻转账", { leading: definition.page === "home" ? undefined : "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "home") {
    content.append(component("app-amount-summary", { label: "点钻余额", amount: fixtures.finance.caibiBalance, asset: "点钻", hint: "点钻使用两位小数，与 USDT 严格隔离" }));
    content.append(component("app-list-tile", { title: "转账", subtitle: "转出方承担 0.5% 手续费", leading: "send" }), component("app-list-tile", { title: "全部账单", subtitle: "红包、转账、提现、充值及其他流水", leading: "document", action: "open:caibi-ledger-all" }));
  } else if (definition.page === "history") content.append(...historyRows("CAIBI"));
  else if (definition.page === "ledger") return ledger(definition);
  else if (definition.page === "transaction") {
    return transactionDetail(definition);
  } else if (definition.state === "receiver-accepted") {
    content.append(
      component("app-transfer-card", { amount: "200.00", state: "accepted", "viewer-role": "receiver", action: "open:caibi-transaction-detail" }),
      component("app-amount-summary", { label: "已收款", amount: "200.00", asset: "点钻", hint: "说明：周然的旅行分摊 · 转账时间 2026-09-10 18:05 · 收款时间 2026-09-10 18:20" }),
      component("app-action-button", { kind: "secondary", icon: "document", label: "查看账单详情", action: "open:caibi-transaction-detail" })
    );
  } else {
    content.append(field("收款用户", definition.state === "recipient-invalid" ? "unknown-user" : "周然", "输入畅聊号"), field("转账金额", definition.state === "amount-invalid" ? "88.123" : fixtures.finance.caibiTransferAmount, "两位小数"));
    content.append(element("section", "c-fee-summary", `金额 ${fixtures.finance.caibiTransferAmount} + 手续费 ${fixtures.finance.caibiFee} = 合计 88.44 点钻`));
    const errors = {
      "recipient-invalid": "未找到收款用户",
      "amount-invalid": "金额必须保留两位小数",
      insufficient: "点钻余额不足",
      duplicate: "请勿重复提交同一笔转账",
      "unknown-result": "结果暂时未知，请查询原交易"
    };
    if (errors[definition.state]) content.append(component("app-toast", { kind: "error", message: errors[definition.state] }));
    content.append(component("app-action-button", { icon: "send", label: definition.state === "processing" ? "处理中…" : definition.state === "success" ? "转账成功" : "确认转账", loading: definition.state === "processing", action: "caibi:transfer" }));
  }
  root.append(content);
  return root;
}

function redpacket(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "detail" ? "领取详情" : "发点钻红包", { leading: "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "detail") {
    const groupRandomTerminal = ["group-random-completed", "group-random-expired"].includes(definition.state);
    const viewerClaim = ["claimed", "viewer-claimed"].includes(definition.state);
    const visualState = viewerClaim ? "claimed" : definition.state === "group-random-completed" ? "exhausted" : definition.state === "group-random-expired" ? "expired" : ["available", "exhausted", "expired", "withdrawn"].includes(definition.state) ? definition.state : "available";
    const statusLabel = { claiming: "领取中", "unknown-result": "状态未知" }[definition.state];
    content.append(component("app-red-packet-card", { state: visualState, greeting: "周末愉快", "viewer-claim": viewerClaim, "status-label": statusLabel, action: viewerClaim ? "open:redpacket-detail-history" : undefined }));
    const messages = {
      claiming: "正在领取，请勿重复点击",
      duplicate: "你已经领取过这个红包",
      "concurrent-exhausted": "手慢了，红包已被领完",
      "unknown-result": "领取结果未知，请刷新红包详情",
      history: "已领取 8/10 份 · 剩余金额将在 24 小时后退回"
    };
    if (messages[definition.state]) content.append(component("app-status-chip", { status: definition.state.includes("unknown") || definition.state.includes("exhausted") ? "warning" : "processing", label: messages[definition.state] }));
    if (viewerClaim) content.append(component("app-amount-summary", { label: "你已领取", amount: "18.88", asset: "点钻", hint: "点击红包直接查看领取详情" }));
    if (groupRandomTerminal) content.append(component("app-transaction-row", { kind: "gift", title: "陈默 · 手气最佳", subtitle: `2026-09-11 09:40 · 群拼手气红包${definition.state.endsWith("expired") ? "已过期" : "已结束"}`, amount: "32.18 点钻", status: "success" }));
    if (definition.state === "history") {
      for (const [name, amount, time] of [["林晓", "18.88 点钻", "2026-09-11 09:41"], ["陈默", "32.18 点钻", "2026-09-11 09:40"]]) {
        content.append(component("app-transaction-row", { kind: "gift", title: name, subtitle: time, amount, status: "success" }));
      }
    }
  } else {
    const typeLabels = { "group-equal": "普通红包", "group-random": "拼手气红包", "group-exclusive": "专属红包", "direct-equal": "私聊普通红包" };
    const directCreate = definition.state === "direct-equal";
    const exclusiveCreate = definition.state === "group-exclusive";
    const fixedSinglePart = directCreate || exclusiveCreate;
    const maxParts = fixedSinglePart ? 1 : Math.min(500, groupRedPacketFixture.joinedMemberIds.length);
    const count = field("红包个数", String(fixedSinglePart ? 1 : maxParts), fixedSinglePart ? "私聊或专属红包仅限 1 份" : `群成员共 ${maxParts} 人，最多可发 ${maxParts} 个红包`);
    const countInput = count.querySelector("input");
    countInput.type = "number";
    countInput.min = "1";
    countInput.max = String(maxParts);
    countInput.setAttribute("aria-label", "红包个数");
    const validation = element("p", "c-ledger-page-note", "");
    const create = component("app-action-button", { icon: "gift", label: definition.state === "success" ? "红包已创建" : "塞钱进红包", loading: definition.state === "submitting", action: "redpacket:create" });
    create.addEventListener("click", event => {
      const raw = countInput.value.trim();
      const parts = /^[1-9]\d*$/u.test(raw) ? Number(raw) : Number.NaN;
      const invalid = !Number.isSafeInteger(parts) || parts > maxParts;
      if (invalid) {
        event.preventDefault();
        event.stopPropagation();
        validation.textContent = fixedSinglePart ? "私聊或专属红包只能创建 1 份" : `红包份数不能超过当前群聊人数（含发送者）：${maxParts}`;
      } else {
        validation.textContent = "";
      }
    });
    content.append(element("div", "c-segmented-control", typeLabels[definition.state] ?? "群聊拼手气"));
    content.append(field("总金额", "88.00", "最高 20000.00 点钻"), count, field("祝福语", "周末愉快", "恭喜发财，大吉大利"), validation);
    const invalidMessage = definition.state === "count-invalid"
      ? (fixedSinglePart ? "私聊或专属红包只能创建 1 份" : `红包份数不能超过当前群聊人数（含发送者）：${maxParts}`)
      : definition.state === "minimum-invalid" ? "每份至少 0.01 点钻"
      : definition.state === "amount-invalid" ? "红包金额格式错误"
      : null;
    if (invalidMessage) content.append(component("app-toast", { kind: "error", message: invalidMessage }));
    content.append(create);    if (definition.state === "confirm") root.append(component("app-dialog", { title: "确认创建红包", message: "88.00 点钻将转入红包托管，24 小时未领取部分自动退回。", cancel: "取消", confirm: "确认" }));
    if (definition.state === "failed") root.append(component("app-toast", { kind: "error", message: "红包创建失败，账户余额不足" }));
  }
  root.append(content);
  return root;
}

function wallet(definition) {
  if (["home", "binding", "deposit", "withdrawal"].includes(definition.page)) return walletBindingDemo(definition);
  const titles = { history: "交易记录", transaction: "交易详情", state: "钱包" };
  const root = pageRoot(definition);
  root.append(navigation(titles[definition.page], { leading: "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "history") {
    if (definition.state === "empty") content.append(component("app-empty-state", { title: "暂无交易记录", message: "充值和提现记录会显示在这里" }));
    else content.append(...historyRows("USDT"));
  } else if (definition.page === "transaction") {
    content.append(component("app-status-chip", { status: "success", label: "链上已确认" }), element("p", "c-wallet-address", definition.state === "detail" ? fixtures.finance.walletAddressFull : fixtures.finance.walletAddress), component("app-action-button", { kind: "secondary", icon: "document", label: "复制完整地址", action: "wallet:copy-address" }));
  } else {
    content.append(component("app-empty-state", { kind: definition.state === "empty" ? "empty" : "network", title: definition.state === "empty" ? "暂无记录" : "钱包暂不可用", message: definition.title, action: "重试" }));
  }
  root.append(content);
  return root;
}

export function renderScreen(definition) {
  const root = definition.module === "caibi" ? caibi(definition) : definition.module === "redpacket" ? redpacket(definition) : wallet(definition);
  return createDeviceScreen(definition, root);
}
