import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppMomentTile extends StrictElement {
  render() {
    const root = element("article", "c-moment-tile");
    root.dataset.state = this.attr("state", "published");
    const avatar = element("div", "c-moment-tile__avatar");
    const avatarComponent = document.createElement("app-avatar");
    avatarComponent.setAttribute("name", this.attr("author", "周然"));
    avatarComponent.setAttribute("size", "moment");
    avatar.append(avatarComponent);
    const content = element("div", "c-moment-tile__content");
    content.append(
      element("h2", "c-moment-tile__author", this.attr("author", "周然")),
      element("p", "c-moment-tile__text", this.attr("content", "天气很好，沿着海边走了很久。"))
    );
    const meta = element("div", "c-moment-tile__meta");
    meta.append(
      element("span", "c-moment-tile__location", this.attr("location", "海滨步道")),
      element("time", "c-moment-tile__time", this.attr("time", "12 分钟前"))
    );
    const action = button("c-moment-tile__action", "动态操作", "moment-menu");
    action.append(icon("more", "c-moment-tile__action-icon"));
    meta.append(action);
    content.append(meta);
    root.append(avatar, content);
    return root;
  }
}

export class AppMomentGrid extends StrictElement {
  render() {
    const count = Math.max(1, Math.min(9, Number(this.attr("count", "3"))));
    const root = element("div", "c-moment-grid");
    root.dataset.count = String(count);
    for (let index = 0; index < count; index += 1) {
      const item = element("figure", "c-moment-grid__item");
      item.dataset.tone = String((index % 4) + 1);
      const image = element("span", "c-moment-grid__image", `图片 ${index + 1}`);
      image.setAttribute("role", "img");
      image.setAttribute("aria-label", `朋友圈图片 ${index + 1}`);
      item.append(image);
      if (this.boolAttr("failed") && index === count - 1) item.append(element("span", "c-moment-grid__error", "上传失败 · 重试"));
      root.append(item);
    }
    return root;
  }
}

export class AppMomentReactions extends StrictElement {
  render() {
    const root = element("section", "c-moment-reactions");
    root.append(
      element("p", "c-moment-reactions__likes", `♥ ${this.attr("likes", "林晓、陈默")}`),
      element("p", "c-moment-reactions__comments", this.attr("comments", "林晓：下次一起走！"))
    );
    return root;
  }
}

export class AppVisibilityIcon extends StrictElement {
  render() {
    const visibility = this.attr("visibility", "friends");
    const labels = { public: "公开", friends: "好友可见", partial: "部分可见", excluded: "不给谁看", private: "仅自己" };
    const root = element("span", "c-visibility-icon");
    root.dataset.visibility = visibility;
    root.append(icon("info", "c-visibility-icon__icon"), element("span", "c-visibility-icon__label", this.attr("label", labels[visibility] ?? labels.friends)));
    return root;
  }
}
