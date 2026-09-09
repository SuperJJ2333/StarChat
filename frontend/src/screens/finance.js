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
  root.append(navigation(definition.page === "home" ? "点钻" : definition.page === "history" ? "点钻记录" : definition.page === "transaction" ? "交易详情" : "点钻转账", { leading: definition.page === "home" ? undefined : "返回" }));
  const content = element("div", "p-finance__content");
  if (definition.page === "home") {
    content.append(component("app-amount-summary", { label: "点钻余额", amount: fixtures.finance.caibiBalance, asset: "点钻", hint: "点钻使用两位小数，与 USDT 严格隔离" }));
    content.append(component("app-list-tile", { title: "转账", subtitle: "转出方承担 0.5% 手续费", leading: "send" }), component("app-list-tile", { title: "交易记录", leading: "document" }));
  } else if (definition.page === "history") content.append(...historyRows("CAIBI"));
  else if (definition.page === "transaction") {
    content.append(component("app-status-chip", { status: "success", label: "交易成功" }), component("app-amount-summary", { label: "交易金额", amount: "88.00", asset: "点钻", hint: "原因码：USER_TRANSFER" }));
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
  root.append(navigation(definition.page === "detail" ? "红包详情" : "发点钻红包", { leading: "返回" }));
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
    const typeLabels = { "group-equal": "普通红包", "group-random": "拼手气红包", "group-exclusive": "专属红包", "direct-equal": "私聊普通红包" };
    content.append(element("div", "c-segmented-control", typeLabels[definition.state] ?? "群聊拼手气"));
    content.append(field("总金额", "88.00", "最高 20000.00 点钻"), field("红包个数", "10", "最多 500 个"), field("祝福语", "周末愉快", "恭喜发财，大吉大利"));
    if (definition.state.includes("invalid")) content.append(component("app-toast", { kind: "error", message: definition.state === "count-invalid" ? "红包份数必须为 1–100" : definition.state === "minimum-invalid" ? "每份至少 0.01 点钻" : "红包金额格式错误" }));
    content.append(component("app-action-button", { icon: "gift", label: definition.state === "success" ? "红包已创建" : "塞钱进红包", loading: definition.state === "submitting", action: "redpacket:create" }));
    if (definition.state === "confirm") root.append(component("app-dialog", { title: "确认创建红包", message: "88.00 点钻将转入红包托管，24 小时未领取部分自动退回。", cancel: "取消", confirm: "确认" }));
    if (definition.state === "failed") root.append(component("app-toast", { kind: "error", message: "红包创建失败，账户余额不足" }));
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
    content.append(component("app-amount-summary", { label: "USDT-TRC20 余额", amount: fixtures.finance.usdtBalance, asset: "USDT", hint: "六位小数 · 与点钻严格隔离" }));
    content.append(component("app-list-tile", { title: "私人钱包与动态验证", subtitle: "验证钱包控制权 · 30 天内仅可改绑一次", leading: "wallet" }), component("app-list-tile", { title: "充值", subtitle: "创建充值意图后转入官方固定地址", leading: "wallet" }), component("app-list-tile", { title: "提现", subtitle: "仅到已绑定钱包 · 官方管理员人工付款", leading: "send" }), component("app-list-tile", { title: "点钻与 USDT 兑换", subtitle: "1 USDT = 1 点钻 · 兑换免手续费 · 开放状态以服务端为准", leading: "wallet" }), component("app-list-tile", { title: "交易记录", leading: "document" }));
  } else if (definition.page === "history") {
    if (definition.state === "empty") content.append(component("app-empty-state", { title: "暂无交易记录", message: "充值和提现记录会显示在这里" }));
    else content.append(...historyRows("USDT"));
  } else if (definition.page === "deposit") {
    content.append(component("app-amount-summary", { label: "官方钱包网络", amount: "TRC20", asset: "USDT", hint: "最低充值 10.000000 USDT · 入账开放状态以服务端为准" }));
    content.append(component("app-status-chip", { status: "warning", label: "充值入账尚未开放，请勿转账。此处仅展示官方钱包地址。" }));
    content.append(element("p", "c-wallet-address", definition.state === "address" || definition.state === "copied" ? fixtures.finance.walletAddressFull : fixtures.finance.walletAddress));
    const labels = { allocating: "正在获取官方地址", copied: "地址已复制", "allocation-failed": "官方地址获取失败", "below-minimum": "低于最低金额，将进入人工处理", detected: "已检测到充值", confirming: "链上确认中", credited: "充值已入账", "manual-review": "充值进入人工复核" };
    content.append(component("app-status-chip", { status: definition.state.includes("failed") ? "error" : definition.state === "credited" || definition.state === "copied" ? "success" : "processing", label: labels[definition.state] ?? "官方钱包地址" }));
  } else if (definition.page === "withdrawal") {
    content.append(field("提现金额", fixtures.finance.usdtWithdrawalAmount, "最低 10.000000 USDT"), element("p", "c-wallet-address", `收款地址由服务端绑定锁定：${fixtures.finance.walletAddress}`));
    content.append(element("section", "c-fee-summary", `本金 ${fixtures.finance.usdtWithdrawalAmount} · 服务费 0.000000 USDT · 到账与冻结等于本金`));
  const labels = { "address-invalid": "请先完成私人钱包绑定", "amount-invalid": "提现金额必须保留六位小数", insufficient: "USDT 余额不足", reviewing: "等待官方管理员领取", "direct-execution": "管理员已领取，请等待人工付款", "provider-processing": "等待人工付款与链上核验", broadcast: "已发现交易，等待固化核验", confirmed: "链上固化匹配，已结算", "failed-refunded": "未领取订单已取消，冻结已释放", "unknown-result": "请求结果未知，只能查询原订单，禁止重复付款", unavailable: "钱包服务暂不可用" };
    if (labels[definition.state]) content.append(component("app-status-chip", { status: definition.state.includes("invalid") || definition.state === "insufficient" || definition.state === "unavailable" ? "error" : definition.state === "confirmed" ? "success" : "processing", label: labels[definition.state] }));
    content.append(component("app-action-button", { icon: definition.state === "unknown-result" ? "search" : "send", label: definition.state === "unknown-result" ? "查询原订单" : "提交提现申请", disabled: definition.state === "unknown-result", action: "wallet:withdrawal" }));
    if (definition.state === "confirm") root.append(component("app-dialog", { title: "确认提现", message: "核对锁定地址、金额和零服务费，输入动态验证码。管理员领取后不可取消；回填交易哈希不代表已结算。", cancel: "取消", confirm: "确认提交" }));
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
