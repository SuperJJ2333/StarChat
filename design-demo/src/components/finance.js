import { StrictElement, element } from "./base.js";
import { icon } from "../icons/icons.js";

const packetLabels = {
  available: "领取红包",
  claimed: "已领取",
  exhausted: "已领完",
  expired: "已过期",
  withdrawn: "已撤回"
};

export class AppRedPacketCard extends StrictElement {
  render() {
    const state = this.attr("state", "available");
    const root = element("article", "c-red-packet");
    root.dataset.state = state;
    const body = element("div", "c-red-packet__body");
    body.append(icon("gift", "c-red-packet__icon"));
    const content = element("div", "c-red-packet__content");
    content.append(
      element("p", "c-red-packet__greeting", this.attr("greeting", "恭喜发财，大吉大利")),
      element("p", "c-red-packet__status", packetLabels[state] ?? packetLabels.available)
    );
    body.append(content);
    root.append(body, element("footer", "c-red-packet__footer", "畅聊点钻红包"));
    return root;
  }
}

export class AppAmountSummary extends StrictElement {
  render() {
    const root = element("section", "c-amount-summary");
    root.append(
      element("p", "c-amount-summary__label", this.attr("label", "可用余额")),
      element("p", "c-amount-summary__value", `${this.attr("amount", "0.00")} ${this.attr("asset", "CAIBI")}`),
      element("p", "c-amount-summary__hint", this.attr("hint", "资产状态以业务服务为准"))
    );
    return root;
  }
}

export class AppTransactionRow extends StrictElement {
  render() {
    const root = element("article", "c-transaction-row");
    root.dataset.status = this.attr("status", "success");
    root.append(icon(this.attr("kind", "wallet"), "c-transaction-row__icon"));
    const body = element("div", "c-transaction-row__body");
    body.append(
      element("h3", "c-transaction-row__title", this.attr("title", "交易记录")),
      element("p", "c-transaction-row__subtitle", this.attr("subtitle", "今天 09:41 · 成功"))
    );
    root.append(body, element("p", "c-transaction-row__amount", this.attr("amount", "+20.000000 USDT")));
    return root;
  }
}
