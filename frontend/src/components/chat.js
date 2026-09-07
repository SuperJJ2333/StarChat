import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppMessageBubble extends StrictElement {
  render() {
    const direction = this.attr("direction", "incoming");
    const delivery = this.attr("delivery", "sent");
    const root = element("article", `c-message c-message--${direction}`);
    root.dataset.direction = direction;
    root.dataset.delivery = delivery;
    const avatar = element("div", "c-message__avatar");
    const avatarComponent = document.createElement("app-avatar");
    avatarComponent.setAttribute("name", this.attr("avatar", direction === "incoming" ? "周" : "林"));
    avatarComponent.setAttribute("size", "message");
    avatar.append(avatarComponent);
    const content = element("div", "c-message__content");
    content.append(element("p", "c-message__sender", this.attr("sender", direction === "incoming" ? "周然" : "我")));
    const row = element("div", "c-message__row");
    row.append(
      element("div", "c-message__bubble", this.attr("content", "明天见，路上注意安全。")),
      element("span", "c-message__delivery", delivery === "failed" ? "!" : "")
    );
    content.append(row);
    root.append(avatar, content);
    return root;
  }
}

export class AppVoiceBubble extends StrictElement {
  render() {
    const root = button("c-voice-bubble", "播放语音", "play-voice");
    root.dataset.playback = this.attr("playback", "idle");
    const wave = element("span", "c-voice-bubble__wave");
    wave.append(...Array.from({ length: 12 }, (_, index) => element("i", `c-voice-bubble__bar c-voice-bubble__bar--${(index % 4) + 1}`)));
    root.append(wave, element("span", "c-voice-bubble__duration", `${this.attr("duration", "8")}″`));
    return root;
  }
}

export class AppAttachmentTile extends StrictElement {
  render() {
    const state = this.attr("state", "sent");
    const root = element("article", "c-attachment");
    root.dataset.state = state;
    root.append(icon("document", "c-attachment__icon"));
    const body = element("div", "c-attachment__body");
    body.append(
      element("h3", "c-attachment__name", this.attr("name", "项目说明.pdf")),
      element("p", "c-attachment__meta", this.attr("meta", "2.4 MB · 端到端加密"))
    );
    const action = button("c-attachment__action", state === "failed" ? "重试上传" : "查看附件", state === "failed" ? "retry-attachment" : "open-attachment");
    action.append(icon(state === "failed" ? "retry" : "chevron", "c-attachment__action-icon"));
    root.append(body, action);
    return root;
  }
}

export class AppTimestamp extends StrictElement {
  render() {
    const root = element("time", "c-timestamp", this.attr("label", "09:41"));
    return root;
  }
}

export class AppUnreadBadge extends StrictElement {
  render() {
    const count = Number(this.attr("count", "1"));
    const root = element("span", "c-unread-badge", count > 99 ? "99+" : String(count));
    root.dataset.muted = String(this.boolAttr("muted"));
    root.setAttribute("aria-label", `${count > 99 ? "99 条以上" : count}未读消息`);
    return root;
  }
}
