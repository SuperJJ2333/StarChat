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
    root.dataset.detail = String(this.boolAttr("detail"));
    const profile = (name, avatarOnly = false) => {
      const control = button("c-moment-reactions__profile", `查看${name}的资料`, `moment:profile:${name}`);
      const avatar = element("app-avatar");
      avatar.setAttribute("name", name);
      avatar.setAttribute("size", "list");
      control.append(avatar);
      if (!avatarOnly) control.append(element("span", "c-moment-reactions__name", name));
      return control;
    };
    const likes = element("div", "c-moment-reactions__likes");
    likes.setAttribute("aria-label", "点赞好友");
    likes.append(element("span", "c-moment-reactions__heart", "♥"));
    for (const name of this.attr("likes", "林晓、陈默").split("、").filter(Boolean)) likes.append(profile(name, true));
    const comments = element("div", "c-moment-reactions__comments");
    for (const value of this.attr("comments", "林晓：下次一起走！").split("\n").filter(Boolean)) {
      const separator = value.indexOf("：");
      const name = separator >= 0 ? value.slice(0, separator) : "好友";
      const text = separator >= 0 ? value.slice(separator + 1) : value;
      const row = element("article", "c-moment-reactions__comment");
      row.dataset.selected = String(this.boolAttr("selected"));
      const header = element("div", "c-moment-reactions__header");
      header.append(profile(name), element("time", "c-moment-reactions__time", this.attr("time", "12 分钟前")));
      const reply = button("c-moment-reactions__reply", this.boolAttr("own") ? "评论操作：复制、删除" : `回复${name}`, this.boolAttr("own") ? "moment:comment-actions" : "moment:reply");
      reply.textContent = text;
      row.append(header, reply);
      comments.append(row);
    }
    root.append(likes, comments);
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

export class AppMomentsFeedV2 extends StrictElement {
  render() {
    const root = element("section", "c-moments-feed-v2");
    const mode = this.attr("mode", "latest");
    root.dataset.mode = mode;
    root.append(element("h2", "c-moments-feed-v2__title", mode === "empty" ? "暂无动态" : "朋友圈"));
    root.append(element("p", "c-moments-feed-v2__message", mode === "loading" ? "正在加载动态…" : mode === "error" ? "加载失败，请重试" : "与好友分享此刻。"));
    return root;
  }
}

export class AppMomentCoverViewer extends StrictElement {
  render() {
    const root = element("figure", "c-moment-cover-viewer");
    const state = this.boolAttr("loading") ? "loading" : this.boolAttr("error") ? "error" : "default";
    root.dataset.state = state;
    const image = element("img", "c-moment-cover-viewer__image");
    image.alt = "朋友圈封面";
    if (this.attr("url")) image.src = this.attr("url");
    root.append(image, element("figcaption", "c-moment-cover-viewer__caption", state === "loading" ? "正在加载封面…" : state === "error" ? "封面加载失败" : "朋友圈封面"));
    return root;
  }
}
