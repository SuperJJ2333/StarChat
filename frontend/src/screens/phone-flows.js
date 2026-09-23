import { walletBindingDemo } from "./wallet-binding.js";
import { redpacket } from "./finance.js";
import { element } from "../components/base.js";
import { icon } from "../icons/icons.js";
import { component, createDeviceScreen, navigation, pageRoot } from "./shared.js";

// ADR-0075/0076/0077/0079：手机号认证、人工充值与转让阶段的 HTML 设计演示。
// 服务端权威为唯一状态来源：提交成功 ≠ 已到账；转让未 COMPLETED ≠ 已换主；
// 汇率过期仅为参考展示；验证码冷却仅为本地演示，不发送真实短信。

const otpField = () => {
  const input = element("input", "c-form-field__input");
  input.placeholder = "6 位验证码";
  input.inputMode = "numeric";
  input.maxLength = 6;
  const wrapper = element("label", "c-form-field");
  wrapper.append(element("span", "c-form-field__label", "短信验证码"), input);
  return { wrapper, input };
};
const field = (labelText, placeholder = "", value = "") => {
  const input = element("input", "c-form-field__input");
  input.placeholder = placeholder;
  if (value) input.value = value;
  const wrapper = element("label", "c-form-field");
  wrapper.append(element("span", "c-form-field__label", labelText), input);
  return { wrapper, input };
};
const card_ = (title) => {
  const node = element("section", "c-phone-flows__card");
  node.append(element("h2", "", title));
  return node;
};
const row = (label, value) => {
  const node = element("div", "c-phone-flows__row");
  node.append(element("span", "c-phone-flows__row-label", label),
    element("span", null, value));
  return node;
};
const hint = (text) => element("p", "c-form-help", text);
const errorLine = (text) => element("p", "c-form-error", text);
const primaryButton = (label, { disabled = false } = {}) =>
  component("app-action-button", { label, kind: "primary", disabled });
const appLogo = () => {
  const mark = element("div", "c-brand-mark", "畅");
  mark.setAttribute("aria-hidden", "true");
  return mark;
};

function authShell(definition, title, buildBody) {
  const root = pageRoot(definition);
  root.classList.add("p-auth");
  const background = element("img", "p-auth__background");
  background.src = "/assets/landing-changliao.png";
  background.alt = "";
  const panel = element("section", "p-auth__panel");
  panel.append(appLogo(), element("h1", "p-auth__title", title));
  const host = element("div", "c-auth-form");
  panel.append(host);
  const draw = () => host.replaceChildren(...buildBody());
  draw();
  root.append(background, panel);
  return createDeviceScreen(definition, root);
}

// ---------------------------------------------------------------- 手机登录
function buildPhoneLogin(state) {
  const nodes = [];
  let seconds = state === "cooldown" ? 54 : 0;
  let requests = state === "cooldown" ? 1 : 0;
  const phone = field("手机号", "+86 手机号",
    state === "error" ? "" : "");
  const otp = otpField();
  const invitation = field('邀请码（仅新用户必填）', '已有账号无需填写');
  const consent = element('input');
  consent.type = 'checkbox';
  const consentRow = element('label', 'c-form-help');
  consentRow.append(consent, element('span', null, '我已阅读并同意用户协议和隐私政策'));
  const validPhone = () => {
    let value = (phone.input.value || '').replace(/[ \-()]/g, '');
    if (value.startsWith('+86')) value = value.slice(3);
    else if (value.startsWith('86') && value.length === 13) value = value.slice(2);
    return /^1[3-9][0-9]{9}$/.test(value);
  };
  const button = component("app-secondary-button", { label: "获取验证码" });
  const otpRow = element("div", "c-phone-flows__otp-row");
  otpRow.append(otp.wrapper, button);
  const errorNode = errorLine(state === "error"
    ? "手机号或验证码错误（剩余 4 次尝试）" : "");
  errorNode.hidden = state !== "error";
  const hintNode = hint(state === "otp-sent" ? "验证码已发送，请在 5 分钟内填写。" : "仅支持中国大陆 +86 手机号。历史聊天记录仍需恢复密钥。");

  const draw = () => {
    errorNode.hidden = errorNode.textContent.length === 0;
    button.setAttribute("label", seconds > 0 ? seconds + " 秒后重发" : "获取验证码");
    otpRow.dataset.eligible = String(validPhone() && seconds === 0 && requests < 3);
    if (!validPhone() || seconds > 0 || requests >= 3) button.setAttribute("disabled", "true");
    else button.removeAttribute("disabled");
    // StrictElement does not observe attributes. Refresh its native button
    // after changing validity/cooldown, keeping this behavior local to the page.
    button.renderContract?.();
  };
  phone.input.addEventListener('input', draw);
  button.addEventListener("click", () => {
    if (!validPhone() || seconds > 0 || requests >= 3) return;
    if (!consent.checked) {
      errorNode.textContent = '请先阅读并同意用户协议和隐私政策';
      draw();
      return;
    }
    requests += 1;
    if (requests >= 3) {
      errorNode.textContent = "请求较频繁，请稍后再试。";
      errorNode.hidden = false;
      draw();
      seconds = 60;
      const timer = setInterval(() => {
        seconds -= 1;
        if (seconds <= 0) { clearInterval(timer); seconds = 0; draw(); return; }
        draw();
      }, 1000);
      return;
    }
    seconds = 60;
    draw();
    const timer = setInterval(() => {
      seconds -= 1;
      if (seconds <= 0) { clearInterval(timer); seconds = 0; draw(); return; }
      draw();
    }, 1000);
  });

  nodes.push(phone.wrapper, otpRow, invitation.wrapper, consentRow, errorNode,
    primaryButton("登录"), hintNode,
    hint('新手机号验证后自动注册，用户名和畅聊号由系统生成；需要有效邀请码。'));
  draw();
  // 启动初始冷却演示（cooldown 态）
  if (seconds > 0) {
    const timer = setInterval(() => {
      seconds -= 1;
      if (seconds <= 0) { clearInterval(timer); draw(); return; }
      draw();
    }, 1000);
  }
  return nodes;
}

// ---------------------------------------------------------------- 手机注册
function buildPhoneRegistration(state) {
  const nodes = [];
  const channel = element("div", "c-phone-flows__channel");
  const phoneOption = element("label", "c-phone-flows__channel-option");
  const phoneRadio = element("input");
  phoneRadio.type = "radio";
  phoneRadio.name = `channel-${state}`;
  phoneRadio.checked = true;
  phoneOption.append(phoneRadio, element("span", null, "手机号注册"));
  const emailOption = element("label", "c-phone-flows__channel-option");
  const emailRadio = element("input");
  emailRadio.type = "radio";
  emailRadio.name = `channel-${state}`;
  emailOption.append(emailRadio, element("span", null, "邮箱注册"));
  emailRadio.addEventListener("change", () => { if (emailRadio.checked) window.location.search = "?screen=auth-registration-default"; });
  channel.append(phoneOption, emailOption);
  nodes.push(channel);
  nodes.push(field("手机号", "+86 手机号").wrapper);
  if (state === "otp" || state === "error") {
    nodes.push(otpField().wrapper);
  }
  if (state === "error") {
    nodes.push(errorLine("验证码不正确，请重新输入"));
  }
  if (state === "matrix-wait") {
    nodes.push(hint("验证成功，正在开通加密通信身份…开通完成后自动进入畅聊。"));
  }
  nodes.push(primaryButton(
    state === "matrix-wait" ? "开通中…" : "下一步",
    { disabled: state === "matrix-wait" }));
  nodes.push(hint("手机号注册使用短信验证码登录；邮箱注册沿用邮件验证。"));
  return nodes;
}

// ---------------------------------------------------------------- 两步换绑
function buildRebind(state) {
  const nodes = [];
  const steps = element("ol", "c-phone-flows__steps");
  steps.append(element("li",
    state === "old" ? "c-phone-flows__step" : "c-phone-flows__step c-phone-flows__step--done",
    "验证当前身份"));
  steps.append(element("li",
    state === "success" ? "c-phone-flows__step c-phone-flows__step--done" : "c-phone-flows__step",
    "绑定新手机号"));
  nodes.push(steps);
  if (state === "old") {
    nodes.push(otpField().wrapper, primaryButton("验证当前手机号"));
    nodes.push(hint("为保障安全，必须先验证当前手机号；仅未绑定手机的邮箱账号走邮箱验证。"));
  } else if (state === "success") {
    nodes.push(hint("手机号已更新，下次请使用新手机号登录。"));
  } else {
    nodes.push(field("新手机号", "+86 新手机号").wrapper, otpField().wrapper);
    if (state === "success") {
      nodes.push(hint("换绑成功，新手机号已生效；旧手机号验证立即失效。"));
    } else {
      nodes.push(primaryButton("确认换绑"));
    }
  }
  return nodes;
}

// ---------------------------------------------------------------- 充值页（复用现行充值页样式）
function rechargeNodes(state) {
  const nodes = [];
  if (state === "directory") {
    const apply = card_("填写金额 · 第 1 步");
    const amount = field("充值金额（USDT）", "0.000000", "50.000000");
    amount.input.inputMode = "decimal";
    const estimate = component("app-amount-summary", {
      label: "预计到账点钻 · 参考", amount: "≈ 356.00", asset: "点钻",
      hint: "参考估算，最终以客服结算为准"
    });
    amount.input.addEventListener("input", () => {
      const value = amount.input.value;
      const valid = /^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$/.test(value);
      const units = valid ? BigInt(value.split(".")[0] + (value.split(".")[1] || "").padEnd(6, "0")) : null;
      const cents = units === null ? null : (units * 712n + 500000n) / 1000000n;
      const digits = cents?.toString().padStart(3, "0");
      estimate.setAttribute("amount", digits ? `≈ ${digits.slice(0, -2)}.${digits.slice(-2)}` : "—");
    });
    const next = primaryButton("下一步");
    next.addEventListener("click", () => {
      const address = row("收款地址", "演示地址 · 不可用于付款");
      const copy = element("button");
      copy.setAttribute("type", "button");
      copy.setAttribute("aria-label", "复制地址");
      copy.setAttribute("style", "width:48px;height:48px;flex:0 0 48px;display:grid;place-items:center;border:0;background:transparent;color:var(--color-brand-primary)");
      copy.append(icon("copy"));
      copy.addEventListener("click", () => navigator.clipboard.writeText("DEMO-NOT-A-PAYMENT-ADDRESS"));
      address.children[1].setAttribute("style", "margin-left:auto;text-align:right;white-space:nowrap;min-width:0;overflow:hidden;text-overflow:ellipsis");
      address.append(copy);
      const qr = element("img");
      qr.setAttribute("src", "./assets/download-qr.png");
      qr.setAttribute("alt", "演示二维码，指向应用下载页，不可用于付款");
      qr.setAttribute("width", "160");
      qr.setAttribute("height", "160");
      const save = element("a", "c-wallet-demo__icon-action", "↓");
      save.setAttribute("aria-label", "保存到本地");
      save.setAttribute("href", "./assets/download-qr.png");
      save.setAttribute("download", "demo-qr.png");
      const qrArea = element("div");
      qrArea.setAttribute("style", "display:flex;flex-direction:column;align-items:center");
      qrArea.append(qr, save);
      apply.replaceChildren(element("h2", "", "客服处理 · 第 2 步"),
        row("订单", "演示订单 req-1"), row("网络", "TRON（TRC20）"),
        row("处理期限", "2 小时 · 截止 2026-09-23 12:00"), address, qrArea);
    });
    apply.append(amount.wrapper, estimate,
      hint("1 USDT ≈ ¥7.12 · 参考估算，最终以客服结算为准"), next);
    nodes.push(apply);
    return nodes;
  }
  if (state === "pending-review") {
    const card = card_("充值申请 · 待核对");
    card.append(row("状态", "待客服核对"));
    card.append(row("原因", "付款凭证需要进一步核实"));
    card.append(hint("客服正在核对付款结果，请勿重复付款。核对完成后将更新申请状态。"));
    nodes.push(card);
    return nodes;
  }
  const card = card_("我的充值申请");
  card.append(row("req-1 · 50 USDT", "处理中 · 未到账"));
  card.append(row("req-2 · 20 USDT", "已到账 · 142.40 点钻"));
  card.append(row("req-3 · 30 USDT", "待核对"));
  card.append(hint("申请提交后需客服核实，到账后可在账单中查看。"));
  nodes.push(card);
  return nodes;
}

// ---------------------------------------------------------------- 汇率与应付
function fxNodes(state) {
  const nodes = [];
  const snapshot = card_(state === "stale" ? "USD/CNY 参考汇率（过期参考）" : "USD/CNY 参考汇率");
  snapshot.append(row("汇率", state === "stale" ? "7.080000（已过期）" : "7.120000"));
  snapshot.append(row("更新时刻", state === "stale" ? "2026-09-23 08:40" : "2026-09-23 09:58"));
  snapshot.append(row("状态", state === "stale" ? "过期参考 · 不用于自动资金结算" : "有效"));
  if (state !== "stale") {
    snapshot.append(hint("1 USDT ≈ 1 USD（参考）；参考估算，最终以客服结算为准。"));
  }
  nodes.push(snapshot);
  if (state !== "stale") {
    const payable = card_("提现最终应付（已批准订单）");
    payable.append(row("点钻本金", "500.00 点钻（1 点钻 = 1 元）"));
    payable.append(row("结算率（客服确认）", "7.120000"));
    payable.append(row("最终 USDT 应付", "70.224719 USDT"));
    payable.append(row("调价记录", "09:58 客服小畅 7.10 → 7.12"));
    payable.append(hint("结算快照不随汇率刷新变化；最低 10 USDT 门槛按 USDT 执行。"));
    nodes.push(payable);
  }
  return nodes;
}

// ---------------------------------------------------------------- 红包抽成（复用红包页视觉）
function commissionNodes(state) {
  const nodes = [];

  const card = card_("手续费与群主抽成");
  card.append(row("红包本金", "100.00 点钻"));
  card.append(row("手续费（0.5%，最低 0.01）",
    state === "fee-exempt" ? "0.00（满 10 人群主本群免手续费）" : "0.50 点钻"));
  card.append(row("群主抽成（0.1%）",
    state === "fee-exempt" ? "无（免手续费不产生抽成）"
      : state === "settled" ? "0.10 点钻 · 已入账群主钱包" : "0.10 点钻 · 待结算"));
  card.append(row("发送者实扣", state === "fee-exempt" ? "100.00 点钻" : "100.50 点钻"));
  card.append(hint(state === "fee-exempt"
    ? "免手续费仅限群主在本群发送；转让/其他群不受影响。"
    : state === "settled"
      ? "红包结算完成，群主收益已入个人钱包。"
      : "手续费最终保留后，抽成一次性入账；过期退回手续费的红包抽成作废。"));
  nodes.push(card);
  return nodes;
}

// ---------------------------------------------------------------- 转让阶段（钱包卡片式）
function transferNodes(state) {
  const nodes = [];
  const summary = card_("转让群主");
  summary.append(row("状态", { pending: "正在处理", review: "待核对", completed: "已完成", unavailable: "暂不可用" }[state]));
  summary.append(hint("从群资料选择新群主并确认后，可在原操作页面查看结果。"));
  nodes.push(summary);
  const owner = card_("群主信息");
  owner.append(row("群主", state === "completed" ? "新群主" : "当前群主"));
  owner.append(row("接任时间",
    state === "completed" ? "2026-09-23 10:00" : "2026-08-01 09:00"));
  nodes.push(owner);
  const noteCard = card_("状态说明");
  noteCard.append(hint({
    pending: "转让处理中：结果未明确前群主不变，也不自动重发。",
    review: "待核对：发送结果不明确，等待人工核对（群主不变）。",
    completed: "转让完成：新群主与接任时间已更新。",
    unavailable: "暂时无法转让群主，请稍后再试。"
  }[state]));
  nodes.push(noteCard);
  return nodes;
}

export function renderScreen(definition) {
  const { page, state } = definition;
  if (page === "login-phone") {
    return authShell(definition, "手机验证码登录", () => buildPhoneLogin(state));
  }
  if (page === "registration-phone") {
    return authShell(definition, "注册畅聊", () => buildPhoneRegistration(state));
  }
  if (page === "rebind") {
    return authShell(definition, "更换手机号", () => buildRebind(state));
  }
  if (["recharge", "fx"].includes(definition.module)) {
    const root = walletBindingDemo({ ...definition, module: "wallet", page: "deposit" }, {
      depositContent: () => definition.module === "fx" ? fxNodes(state) : rechargeNodes(page)
    });
    return createDeviceScreen(definition, root);
  }
  if (definition.module === "commission") {
    const root = redpacket({ ...definition, module: "redpacket", page: "detail", state: state === "settled" ? "exhausted" : "available" }, { details: commissionNodes(state) });
    return createDeviceScreen(definition, root);
  }
  const container = pageRoot(definition);
  container.append(navigation({
    directory: "人工充值", history: "人工充值", "pending-review": "人工充值 · 待核对",
    fx: "汇率与提现",
    commission: "红包费用明细",
    transfer: "群主转让"
  }[page] ?? "畅聊"));
  const body = element("div", "p-finance__content");
  if (page === "directory") body.append(...rechargeNodes("directory"));
  else if (page === "history") body.append(...rechargeNodes("history"));
  else if (page === "pending-review") body.append(...rechargeNodes("pending-review"));
  else if (page === "fx") body.append(...fxNodes(state));
  else if (page === "commission") body.append(...commissionNodes(state));
  else if (page === "transfer") body.append(...transferNodes(state));
  container.append(body);
  return createDeviceScreen(definition, container);
}
