import { StrictElement, button, element } from "./base.js";
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
    const action = this.attr("action");
    const statusLabel = this.attr("status-label", packetLabels[state] ?? packetLabels.available);
    const root = action ? button("c-red-packet", this.attr("greeting", "恭喜发财，大吉大利"), action) : element("article", "c-red-packet");
    if (action) root.type = "button";
    root.dataset.state = state;
    root.dataset.viewerClaim = String(this.boolAttr("viewer-claim"));
    const body = element("div", "c-red-packet__body");
    body.append(icon("gift", "c-red-packet__icon"));
    const content = element("div", "c-red-packet__content");
    content.append(
      element("p", "c-red-packet__greeting", this.attr("greeting", "恭喜发财，大吉大利")),
      element("p", "c-red-packet__status", statusLabel)
    );
    body.append(content);
    root.append(body, element("footer", "c-red-packet__footer", "畅聊点钻红包"));
    return root;
  }
}

const transferLabels = {
  pending: { sender: "等待收款", receiver: "点击收款" },
  accepted: { sender: "对方已收款", receiver: "转账已收款" },
  returned: { sender: "已退回", receiver: "已退回" }
};

export class AppTransferCard extends StrictElement {
  render() {
    const state = this.attr("state", "pending");
    const role = this.attr("viewer-role", "sender");
    const action = this.attr("action");
    const label = transferLabels[state]?.[role] ?? transferLabels.pending.sender;
    const root = action ? button("c-transfer-card", label, action) : element("article", "c-transfer-card");
    if (action) root.type = "button";
    root.dataset.state = state;
    root.dataset.viewerRole = role;
    const body = element("div", "c-transfer-card__body");
    body.append(
      element("p", "c-transfer-card__amount", `${this.attr("amount", "0.00")} 点钻`),
      element("p", "c-transfer-card__status", label)
    );
    root.append(body, element("footer", "c-transfer-card__footer", "畅聊点钻转账"));
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
