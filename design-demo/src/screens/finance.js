import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
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

function caibi(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "home" ? "彩币" : definition.page === "history" ? "彩币记录" : definition.page === "transaction" ? "交易详情" : "彩币转账", { leading: definition.page === "home" ? undefined : "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "home") {
    content.append(component("app-amount-summary", { label: "彩币余额", amount: fixtures.finance.caibiBalance, asset: "彩币", hint: "彩币使用两位小数，与 USDT 严格隔离" }));
    content.append(component("app-list-tile", { title: "转账", subtitle: "转出方承担 0.5% 手续费", leading: "send" }), component("app-list-tile", { title: "交易记录", leading: "document" }));
  } else if (definition.page === "history") content.append(...historyRows("CAIBI"));
  else if (definition.page === "transaction") {
    content.append(component("app-status-chip", { status: "success", label: "交易成功" }), component("app-amount-summary", { label: "交易金额", amount: "88.00", asset: "彩币", hint: "原因码：USER_TRANSFER" }));
  } else {
    content.append(field("收款用户", definition.state === "recipient-invalid" ? "unknown-user" : "周然", "输入畅聊号"), field("转账金额", definition.state === "amount-invalid" ? "88.123" : fixtures.finance.caibiTransferAmount, "两位小数"));
    content.append(element("section", "c-fee-summary", `金额 ${fixtures.finance.caibiTransferAmount} + 手续费 ${fixtures.finance.caibiFee} = 合计 88.44 彩币`));
    const errors = {
      "recipient-invalid": "未找到收款用户",
      "amount-invalid": "金额必须保留两位小数",
      insufficient: "彩币余额不足",
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
  root.append(navigation(definition.page === "detail" ? "红包详情" : "发彩币红包", { leading: "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "detail") {
    const visualState = ["available", "claimed", "exhausted", "expired", "withdrawn"].includes(definition.state) ? definition.state : "available";
    content.append(component("app-red-packet-card", { state: visualState, greeting: "周末愉快" }));
    const messages = {
      claiming: "正在领取，请勿重复点击",
      duplicate: "你已经领取过这个红包",
      "concurrent-exhausted": "手慢了，红包已被领完",
      "unknown-result": "领取结果未知，请刷新红包详情",
      history: "已领取 8/10 份 · 剩余金额将在 24 小时后退回"
    };
    if (messages[definition.state]) content.append(component("app-status-chip", { status: definition.state.includes("unknown") || definition.state.includes("exhausted") ? "warning" : "processing", label: messages[definition.state] }));
    if (definition.state === "history") content.append(...historyRows("CAIBI"));
  } else {
    const typeLabels = { "group-equal": "群聊等额", "group-random": "群聊拼手气", "direct-equal": "私聊等额", "direct-random": "私聊拼手气" };
    content.append(element("div", "c-segmented-control", typeLabels[definition.state] ?? "群聊拼手气"));
    content.append(field("总金额", "88.00", "最多 10000.00"), field("红包份数", "10", "最多 100 份"), field("祝福语", "周末愉快", "恭喜发财，大吉大利"));
    if (definition.state.includes("invalid")) content.append(component("app-toast", { kind: "error", message: definition.state === "count-invalid" ? "红包份数必须为 1–100" : definition.state === "minimum-invalid" ? "每份至少 0.01 彩币" : "红包金额格式错误" }));
    content.append(component("app-action-button", { icon: "gift", label: definition.state === "success" ? "红包已创建" : "塞钱进红包", loading: definition.state === "submitting", action: "redpacket:create" }));
    if (definition.state === "confirm") root.append(component("app-dialog", { title: "确认创建红包", message: "88.00 彩币将转入红包托管，24 小时未领取部分自动退回。", cancel: "取消", confirm: "确认" }));
    if (definition.state === "failed") root.append(component("app-toast", { kind: "error", message: "红包创建失败，彩币余额未改变" }));
  }
  root.append(content);
  return root;
}

function wallet(definition) {
  const titles = { home: "USDT 钱包", history: "交易记录", deposit: "USDT-TRC20 充值", withdrawal: "USDT-TRC20 提现", transaction: "交易详情", state: "USDT 钱包" };
  const root = pageRoot(definition);
  root.append(navigation(titles[definition.page], { leading: definition.page === "home" ? undefined : "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "home") {
    content.append(component("app-amount-summary", { label: "USDT-TRC20 余额", amount: fixtures.finance.usdtBalance, asset: "USDT", hint: "六位小数 · 与彩币严格隔离" }));
    content.append(component("app-list-tile", { title: "充值", subtitle: "获取专属测试充值地址", leading: "wallet" }), component("app-list-tile", { title: "提现", subtitle: "提交后进入财务审核", leading: "send" }), component("app-list-tile", { title: "交易记录", leading: "document" }));
  } else if (definition.page === "history") {
    if (definition.state === "empty") content.append(component("app-empty-state", { title: "暂无交易记录", message: "充值和提现记录会显示在这里" }));
    else content.append(...historyRows("USDT"));
  } else if (definition.page === "deposit") {
    content.append(component("app-amount-summary", { label: "充值网络", amount: "TRC20", asset: "USDT", hint: "最低充值 1 USDT，达到 20 个确认后到账" }));
    content.append(element("p", "c-wallet-address", definition.state === "address" || definition.state === "copied" ? fixtures.finance.walletAddressFull : fixtures.finance.walletAddress));
    const labels = { allocating: "正在分配充值地址", copied: "地址已复制", "allocation-failed": "地址分配失败", "below-minimum": "低于最低金额，将进入人工处理", detected: "已检测到充值", confirming: "链上确认中", credited: "充值已入账", "manual-review": "充值进入人工复核" };
    content.append(component("app-status-chip", { status: definition.state.includes("failed") ? "error" : definition.state === "credited" || definition.state === "copied" ? "success" : "processing", label: labels[definition.state] ?? "充值地址已生成" }));
  } else if (definition.page === "withdrawal") {
    content.append(field("提现金额", fixtures.finance.usdtWithdrawalAmount, "六位小数"), field("TRC20 地址", definition.state === "address-invalid" ? "invalid-address" : fixtures.finance.walletAddress, "输入提现地址"));
    content.append(element("section", "c-fee-summary", `提现 ${fixtures.finance.usdtWithdrawalAmount} + 费用 ${fixtures.finance.usdtFee} USDT`));
    const labels = { "address-invalid": "TRC20 地址格式错误", "amount-invalid": "提现金额必须保留六位小数", insufficient: "USDT 余额不足", reviewing: "财务审核中", "second-approval": "等待第二位审批人", "provider-processing": "托管方处理中", broadcast: "已广播到 TRON 网络", confirmed: "链上已确认", "failed-refunded": "提现失败，资金已退款", "unknown-result": "请求结果未知，只能查询原订单", unavailable: "钱包服务暂不可用" };
    if (labels[definition.state]) content.append(component("app-status-chip", { status: definition.state.includes("invalid") || definition.state === "insufficient" || definition.state === "unavailable" ? "error" : definition.state === "confirmed" ? "success" : "processing", label: labels[definition.state] }));
    content.append(component("app-action-button", { icon: definition.state === "unknown-result" ? "search" : "send", label: definition.state === "unknown-result" ? "查询原订单" : "提交提现申请", disabled: definition.state === "unknown-result", action: "wallet:withdrawal" }));
    if (definition.state === "confirm") root.append(component("app-dialog", { title: "确认提现", message: "提交后将进入财务审核，托管方提交后不可取消。", cancel: "取消", confirm: "确认提交" }));
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
