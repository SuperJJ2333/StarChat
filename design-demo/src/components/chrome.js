import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppStatusBar extends StrictElement {
  render() {
    const root = element("header", "c-status-bar");
    root.append(
      element("span", "c-status-bar__time", this.attr("time", "9:41")),
      element("span", "c-status-bar__island", ""),
      element("span", "c-status-bar__indicators", "5G  ▰")
    );
    root.setAttribute("aria-label", "设备状态栏");
    return root;
  }
}

export class AppNavigationBar extends StrictElement {
  render() {
    const root = element("nav", "c-navigation-bar");
    root.setAttribute("aria-label", "页面导航");
    const leading = element("div", "c-navigation-bar__leading");
    if (this.attr("leading")) {
      const back = button("c-navigation-bar__button", this.attr("leading"), "back");
      back.append(icon("back", "c-navigation-bar__icon"));
      leading.append(back);
    }
    const title = element("h1", "c-navigation-bar__title", this.attr("title", "畅聊"));
    const actions = element("div", "c-navigation-bar__actions");
    if (this.attr("action")) {
      const action = button("c-navigation-bar__button", this.attr("action"), "navigation-action");
      action.append(icon("more", "c-navigation-bar__icon"));
      actions.append(action);
    }
    root.append(leading, title, actions);
    return root;
  }
}

export class AppTabBar extends StrictElement {
  render() {
    const active = this.attr("active", "messages");
    const items = [
      ["messages", "消息", "chat"],
      ["contacts", "通讯录", "contact"],
      ["discovery", "发现", "discovery"],
      ["profile", "我", "me"]
    ];
    const root = element("nav", "c-tab-bar");
    root.setAttribute("aria-label", "主导航");
    for (const [value, label, iconName] of items) {
      const item = button("c-tab-bar__item", label, `tab:${value}`);
      item.dataset.active = String(value === active);
      item.append(icon(iconName, "c-tab-bar__icon"), element("span", "c-tab-bar__label", label));
      root.append(item);
    }
    return root;
  }
}
