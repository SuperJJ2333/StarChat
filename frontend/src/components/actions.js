import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppActionButton extends StrictElement {
  render() {
    const kind = this.attr("kind", "primary");
    const label = this.attr("label", "继续");
    const loading = this.boolAttr("loading");
    const root = button(`c-action-button c-action-button--${kind}`, label, this.attr("action"));
    root.dataset.loading = String(loading);
    root.disabled = this.boolAttr("disabled") || loading;
    root.append(
      icon(this.attr("icon", "check"), "c-action-button__icon"),
      element("span", "c-action-button__label", label),
      element("span", "c-action-button__progress", loading ? "···" : "")
    );
    return root;
  }
}

export class AppComposer extends StrictElement {
  render() {
    const mode = this.attr("mode", "text");
    const root = element("form", "c-composer");
    root.dataset.mode = mode;
    const modeButton = button("c-composer__mode", mode === "voice" ? "切换键盘" : "切换语音", "composer-mode");
    modeButton.append(icon(mode === "voice" ? "chat" : "microphone", "c-composer__icon"));
    const field = element(mode === "voice" ? "button" : "input", "c-composer__field");
    if (mode === "voice") {
      field.type = "button";
      field.textContent = "按住说话";
    } else {
      field.type = "text";
      field.placeholder = this.attr("placeholder", "发送消息");
      field.setAttribute("aria-label", "消息内容");
    }
    field.disabled = this.boolAttr("disabled");
    const send = button("c-composer__send", "发送", "send-message");
    send.append(icon("send", "c-composer__icon"));
    root.append(modeButton, field, send);
    return root;
  }
}
