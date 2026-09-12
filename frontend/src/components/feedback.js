import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

const statusIcons = {
  processing: "info",
  success: "check",
  warning: "warning",
  error: "error"
};

export class AppStatusChip extends StrictElement {
  render() {
    const status = this.attr("status", "processing");
    const root = element("span", "c-status-chip");
    root.dataset.status = status;
    root.append(
      icon(statusIcons[status] ?? "info", "c-status-chip__icon"),
      element("span", "c-status-chip__label", this.attr("label", "处理中"))
    );
    return root;
  }
}

export class AppDialog extends StrictElement {
  render() {
    const titleId = `dialog-${this.attr("kind", "confirm")}-title`;
    const root = element("div", "c-dialog-overlay");
    const overlay = element("div", "c-overlay");
    overlay.append(element("div", "c-overlay__scrim"));
    const dialog = element("section", "c-dialog");
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-labelledby", titleId);
    const header = element("header", "c-dialog__header");
    const title = element("h2", "c-dialog__title", this.attr("title", "确认操作"));
    title.id = titleId;
    header.append(title);
    const content = element("div", "c-dialog__content", this.attr("message", "请确认是否继续。"));
    const actions = element("footer", "c-dialog__actions");
    const cancel = button("c-dialog__button", this.attr("cancel", "取消"), "dialog-cancel");
    cancel.textContent = this.attr("cancel", "取消");
    const confirm = button("c-dialog__button c-dialog__button--confirm", this.attr("confirm", "确认"), "dialog-confirm");
    confirm.textContent = this.attr("confirm", "确认");
    if (this.attr("kind") === "history-choice") {
      title.textContent = "是否删除本机聊天记录？";
      content.textContent = "保存可在重新登录后继续查看。删除会清除本机聊天数据与加密密钥；未备份的记录可能无法恢复。";
      const save = button("c-dialog__button c-dialog__button--default", "保存", "dialog-save");
      save.textContent = "保存";
      save.setAttribute("autofocus", "");
      confirm.className = "c-dialog__button c-dialog__button--destructive";
      confirm.textContent = "确认删除";
      confirm.setAttribute("aria-label", "确认删除");
      actions.append(cancel, save, confirm);
    } else {
      if (!this.boolAttr("hide-cancel")) actions.append(cancel);
      actions.append(confirm);
    }
    dialog.append(header, content, actions);
    overlay.append(dialog);
    root.append(overlay);
    return root;
  }
}

export class AppActionSheet extends StrictElement {
  render() {
    const root = element("div", "c-action-sheet-overlay");
    const overlay = element("div", "c-overlay");
    overlay.append(element("div", "c-overlay__scrim"));
    const variant = this.attr("variant");
    // "fit": 与 Flutter 端 WeChatMoreSheet 对齐——宽度适配内容、水平居中
    //（问题二：全宽底部菜单两侧空白过宽）。
    const sheet = element("section", variant === "fit" ? "c-action-sheet c-action-sheet--fit" : "c-action-sheet");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-modal", "true");
    const header = element("header", "c-action-sheet__header");
    header.append(element("h2", "c-action-sheet__title", this.attr("title", "请选择")));
    const body = element("div", "c-action-sheet__body");
    const selected = this.attr("selected");
    for (const option of this.attr("options", "全部,最近半年,最近一个月,最近三天").split(",")) {
      const item = button("c-action-sheet__option", option, `sheet:${option}`);
      item.dataset.selected = String(option === selected);
      item.textContent = option;
      body.append(item);
    }
    const footer = element("footer", "c-action-sheet__footer");
    const cancel = button("c-action-sheet__cancel", "取消", "sheet-cancel");
    cancel.textContent = "取消";
    footer.append(cancel);
    sheet.append(header, body, footer);
    overlay.append(sheet);
    root.append(overlay);
    return root;
  }
}

export class AppToast extends StrictElement {
  render() {
    const kind = this.attr("kind", "info");
    const root = element("div", "c-toast");
    root.dataset.kind = kind;
    root.setAttribute("role", kind === "error" ? "alert" : "status");
    root.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
    root.append(icon(statusIcons[kind] ?? "info", "c-toast__icon"), element("p", "c-toast__message", this.attr("message", "操作已完成")));
    return root;
  }
}

export class AppEmptyState extends StrictElement {
  render() {
    const kind = this.attr("kind", "empty");
    const root = element("section", "c-empty-state");
    root.dataset.kind = kind;
    root.append(
      icon(kind === "network" ? "network" : kind === "error" ? "error" : "info", "c-empty-state__icon"),
      element("h2", "c-empty-state__title", this.attr("title", "暂无内容")),
      element("p", "c-empty-state__message", this.attr("message", "这里暂时没有可显示的内容。"))
    );
    if (this.attr("action")) {
      const action = button("c-empty-state__action", this.attr("action"), "empty-action");
      action.textContent = this.attr("action");
      root.append(action);
    }
    return root;
  }
}

export class AppNetworkCapsule extends StrictElement {
  render() {
    const state = this.attr("state", "offline");
    if (state === "restored") return document.createDocumentFragment();
    const labels = {
      offline: "网络不可用，联网后自动重试",
      reconnecting: "正在连接…",
      connecting: "正在连接…",
      "service-unavailable": "服务暂时不可用"
    };
    const root = button("c-network-capsule", labels[state] ?? labels.offline, "retry-network");
    root.dataset.state = state;
    root.disabled = this.boolAttr("disabled") || state === "reconnecting" || state === "connecting";
    root.append(icon("network", "c-network-capsule__icon"), element("span", "c-network-capsule__label", this.attr("label", labels[state] ?? labels.offline)));
    return root;
  }
}

export class AppNudgeNotice extends StrictElement {
  render() {
    const root = element("p", "c-nudge-notice", this.attr("text", "轻触提醒已发送"));
    root.setAttribute("role", "status");
    root.setAttribute("aria-live", "polite");
    return root;
  }
}
