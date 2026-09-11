import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { icon } from "../icons/icons.js";
import { navigation, pageRoot } from "./shared.js";

// A local interaction demo only: never request a real PIN or submit a payment.
const demoBalance = fixtures.finance.caibiBalance;
const withdrawalStates = {
  reviewing: "等待管理员处理", "direct-execution": "管理员处理中",
  "provider-processing": "等待付款与核验", broadcast: "链上确认中",
  confirmed: "已完成", "failed-refunded": "订单已取消，资金已退回",
  "unknown-result": "提交结果尚不明确，请查询原订单后再操作",
};
function cents(value) {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) return null;
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
}
function action(label, handler, { disabled = false, secondary = false } = {}) {
  const node = element("button", `c-wallet-demo__button${secondary ? " c-wallet-demo__button--secondary" : ""}`, label);
  node.type = "button"; node.disabled = disabled;
  node.addEventListener("click", handler);
  return node;
}
function inputField(label, value, placeholder) {
  const wrapper = element("label", "c-finance-field");
  const input = element("input", "c-finance-field__input");
  input.value = value; input.placeholder = placeholder;
  wrapper.append(element("span", "c-finance-field__label", label), input);
  return { wrapper, input };
}

export function walletBindingDemo(definition) {
  const root = pageRoot(definition);
  let page = definition.page;
  let bound = !["unbound", "binding", "address-invalid"].includes(definition.state);
  let ready = !["unavailable", "allocating", "allocation-failed"].includes(definition.state);
  let amount = definition.state === "amount-invalid" ? "1" : definition.state === "insufficient" ? "99999" : "20.00";
  let pin = "", note = "", error = ({
    "pin-error": "支付密码错误，请重新输入",
    "amount-invalid": "最低提现10 USDT，金额最多保留两位小数",
    insufficient: "点钻余额不足",
  })[definition.state] ?? "";
  if (["payment-pin", "pin-error", "confirm"].includes(definition.state)) page = "pin";
  if (definition.state === "pin-cancelled") note = "已取消，未提交提现申请";
  const jump = (target) => { pin = ""; error = ""; note = ""; page = target; draw(); };
  function draw() {
    root.replaceChildren();
    root.append(navigation("钱包"));
    const body = element("div", "p-finance__content c-wallet-demo");
    body.append(element("p", "c-wallet-demo__notice", "交互演示 · 示例数据，不会提交真实申请"));
    if (page !== "home") body.append(action(page === "pin" ? "取消" : "返回", () => {
      const cancelling = page === "pin";
      jump(cancelling ? "withdrawal" : "home");
      if (cancelling) { note = "已取消，未提交提现申请"; draw(); }
    }, { secondary: true }));
    if (page === "home") {
      const card = element("section", "c-wallet-demo__card");
      const heading = element("div", "c-wallet-demo__card-heading");
      heading.append(element("h2", "", "TRON"));
      const change = action("", () => jump("binding"), { secondary: true });
      change.classList.add("c-wallet-demo__change");
      change.setAttribute("aria-label", bound ? "更改绑定钱包" : "绑定钱包");
      change.append(icon("edit"));
      heading.append(change);
      card.append(heading, element("p", "", bound ? "已绑定私人钱包" : "尚未绑定私人钱包"),
        element("p", "c-wallet-demo__address", bound ? fixtures.finance.walletAddress : "绑定后可充值和提现"));
      if (!ready) card.append(element("p", "c-wallet-demo__error", "钱包暂不可用，请稍后重试"));
      body.append(card);
      const shortcuts = element("div", "c-wallet-demo__shortcuts");
      shortcuts.append(action("充值", () => jump("deposit"), { disabled: !bound || !ready }),
        action("提现", () => jump("withdrawal"), { disabled: !bound || !ready }));
      body.append(shortcuts);
      if (!bound) body.append(action("绑定私人钱包", () => jump("binding"), { secondary: true }));
      if (!ready) body.append(action("重新加载演示", () => { ready = true; draw(); }, { secondary: true }));
    } else if (page === "binding") {
      body.append(element("h2", "", bound ? "更改绑定钱包" : "绑定私人钱包"),
        element("p", "", "请使用你自己的 TRON 钱包完成控制权验证。"),
        element("p", "c-wallet-demo__muted", "30天内仅可改绑一次。实际可改绑时间以账户显示为准。"));
      const address = inputField("钱包地址", "", "TRON 地址（演示中无需填写真实地址）");
      body.append(address.wrapper,
        action("查看绑定中状态", () => { bound = false; note = "等待钱包控制权验证，充值和提现尚不可用"; draw(); }, { secondary: true }),
        action("切换为已绑定演示", () => { bound = true; ready = true; jump("home"); }));
    } else if (page === "deposit") {
      body.append(element("h2", "", "充值"), element("p", "", "USDT · TRON（TRC20）"));
      if (!bound || !ready) {
        body.append(element("p", "c-wallet-demo__error", !bound ? "请先绑定私人钱包" : definition.state === "allocating" ? "正在获取官方充值地址…" : "官方充值地址暂不可用"),
          action("充值申请", () => {}, { disabled: true }));
      } else {
        const depositStatus = { detected: "已检测到充值", confirming: "链上确认中",
          credited: "充值已入账", "manual-review": "人工复核中",
          "below-minimum": "低于最低金额，请按提示处理", copied: "地址已复制" }[definition.state];
        if (depositStatus) body.append(element("p", "c-wallet-demo__muted", `状态示例：${depositStatus}`));
        body.append(element("p", "c-wallet-demo__address", fixtures.finance.walletAddressFull),
          element("p", "c-wallet-demo__muted", "最低充值 10 USDT，请仅使用已绑定的私人钱包转入。"));
        const deposit = inputField("充值金额", "10.00", "最低10 USDT");
        deposit.input.inputMode = "decimal";
        body.append(deposit.wrapper, action("确认充值申请", () => {
          const value = cents(deposit.input.value);
          note = value === null || value < 1000n ? "请输入至少10 USDT的金额" : "演示已完成，未创建充值申请，请勿向示例地址转账";
          feedback();
        }));
      }
    } else if (page === "withdrawal") {
      body.append(element("h2", "", "提现"), element("p", "", `当前点钻余额 ${demoBalance}`),
        element("p", "c-wallet-demo__address", `收款钱包：${fixtures.finance.walletAddress}`));
      const amountField = inputField("提现金额（USDT）", amount, "最低10 USDT");
      amountField.input.inputMode = "decimal";
      amountField.input.addEventListener("input", () => { amount = amountField.input.value; error = ""; });
      const full = action("全额", () => { amount = demoBalance; amountField.input.value = amount; error = ""; }, { secondary: true });
      const summary = element("section", "c-fee-summary", "1点钻 = 1USDT · 手续费0 · 最低提现10USDT");
      body.append(amountField.wrapper, full, summary);
      const status = withdrawalStates[definition.state];
      if (status) body.append(element("p", "c-wallet-demo__muted", `订单状态示例：${status}`));
      if (!bound || !ready) error = !bound ? "请先绑定私人钱包" : "钱包服务暂不可用";
      body.append(action("确认提现", () => {
        const value = cents(amount);
        if (value === null || value < 1000n) error = "最低提现10 USDT，金额最多保留两位小数";
        else if (value > cents(demoBalance)) error = "点钻余额不足";
        else { jump("pin"); return; }
        feedback();
      }, { disabled: !bound || !ready || Boolean(status) }));
      if (definition.state === "unknown-result") body.append(action("查询原订单", () => {
        note = "演示订单结果仍未知；不会新建订单或重复付款"; feedback();
      }, { secondary: true }));
    } else if (page === "pin") {
      body.append(element("section", "c-wallet-demo__pin-summary"));
      const summary = body.lastElementChild;
      summary.append(element("p", "", `提现至 ${fixtures.finance.walletAddress}`),
        element("h2", "c-wallet-demo__amount", `${amount} USDT`), element("p", "", "手续费 0 USDT"),
        element("p", "", "请输入支付密码"), element("p", "c-wallet-demo__muted", "演示密码123456，请勿输入真实密码"));
      const boxes = element("div", "c-wallet-demo__pin-boxes");
      boxes.setAttribute("aria-label", `支付密码，已输入${pin.length}位，共6位`);
      for (let i = 0; i < 6; i++) boxes.append(element("span", "", i < pin.length ? "●" : ""));
      const keys = element("div", "c-wallet-demo__keys");
      for (const key of ["1", "2", "3", "4", "5", "6", "7", "8", "9", "清空", "0", "删除"]) keys.append(action(key, () => {
        pin = key === "清空" ? "" : key === "删除" ? pin.slice(0, -1) : (pin + key).slice(0, 6);
        error = ""; draw();
      }, { secondary: true }));
      body.append(boxes, keys, action("确认", () => {
        if (pin !== "123456") { pin = ""; error = "支付密码错误，请重新输入"; draw(); return; }
        pin = ""; page = "withdrawal"; note = "演示确认完成，未提交提现申请、未扣款"; draw();
      }, { disabled: pin.length !== 6 }));
    }
    const message = element("p", "c-wallet-demo__feedback");
    message.setAttribute("role", "status"); body.append(message);
    function feedback() { message.textContent = error || note; message.classList.toggle("c-wallet-demo__error", Boolean(error)); }
    feedback(); root.append(body);
  }
  draw(); return root;
}
