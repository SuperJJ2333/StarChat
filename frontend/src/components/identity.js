import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppAvatar extends StrictElement {
  render() {
    const name = this.attr("name", "畅");
    const root = element("figure", "c-avatar");
    root.dataset.size = this.attr("size", "conversation");
    const image = element("img", "c-avatar__image");
    image.alt = this.attr("image") ? `${name}的头像` : "";
    if (this.attr("image")) image.src = this.attr("image");
    const fallback = element("span", "c-avatar__fallback", name.trim().slice(0, 1) || "畅");
    fallback.setAttribute("aria-hidden", "true");
    const badge = element("span", "c-avatar__badge", this.attr("badge"));
    badge.setAttribute("aria-label", this.attr("badge") ? `未读 ${this.attr("badge")}` : "");
    root.append(image, fallback, badge);
    return root;
  }
}

export class AppListTile extends StrictElement {
  render() {
    const root = element("article", "c-list-tile");
    root.dataset.disabled = String(this.boolAttr("disabled"));
    const leading = element("div", "c-list-tile__leading");
    leading.append(icon(this.attr("leading", "info"), "c-list-tile__icon"));
    const body = element("div", "c-list-tile__body");
    body.append(element("h3", "c-list-tile__title", this.attr("title", "列表项目")));
    if (this.attr("subtitle")) body.append(element("p", "c-list-tile__subtitle", this.attr("subtitle")));
    const trailing = element("div", "c-list-tile__trailing");
    trailing.append(element("span", "c-list-tile__trailing-label", this.attr("trailing")), icon("chevron", "c-list-tile__chevron"));
    if (this.attr("action")) {
      root.tabIndex = 0;
      root.dataset.action = this.attr("action");
      root.setAttribute("role", "button");
    }
    root.append(leading, body, trailing);
    return root;
  }
}

export class AppIdentityHeader extends StrictElement {
  render() {
    const root = element("article", "c-identity-header");
    const avatar = element("div", "c-identity-header__avatar");
    const avatarComponent = document.createElement("app-avatar");
    avatarComponent.setAttribute("name", this.attr("name", "林晓"));
    avatarComponent.setAttribute("size", "detail");
    if (this.attr("image")) avatarComponent.setAttribute("image", this.attr("image"));
    avatar.append(avatarComponent);
    const body = element("div", "c-identity-header__body");
    body.append(
      element("h2", "c-identity-header__name", this.attr("name", "林晓")),
      element("p", "c-identity-header__username", `畅聊号：${this.attr("username", "linxiao")}`),
      element("p", "c-identity-header__signature", this.attr("signature", "保持好奇，也保持联系。"))
    );
    root.append(avatar, body);
    return root;
  }
}

export class AppContactIndex extends StrictElement {
  render() {
    const root = element("nav", "c-contact-index");
    root.setAttribute("aria-label", "联系人字母索引");
    const active = this.attr("active", "L");
    for (const letter of "ABCDEFGHIJKLMNOPQRSTUVWXYZ#") {
      const item = button("c-contact-index__letter", `跳到 ${letter}`, `contact-index:${letter}`);
      item.textContent = letter;
      item.dataset.active = String(letter === active);
      root.append(item);
    }
    return root;
  }
}

class AppContactTagPanel extends StrictElement {
  render() {
    const root = element("section", this.constructor.rootClass);
    root.append(element("h2", `${this.constructor.rootClass}__title`, this.constructor.title));
    root.append(element("p", `${this.constructor.rootClass}__message`, this.attr("tag", "未分组联系人")));
    return root;
  }
}

export class AppContactTagManagement extends AppContactTagPanel {
  static rootClass = "c-contact-tags";
  static title = "联系人标签";
}

export class AppContactTagMembers extends AppContactTagPanel {
  static rootClass = "c-contact-tag-members";
  static title = "标签成员";
}

export class AppContactTagFriendPicker extends AppContactTagPanel {
  static rootClass = "c-contact-tag-picker";
  static title = "选择联系人";
}
