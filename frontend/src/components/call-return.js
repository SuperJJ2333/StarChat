import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

export class AppCallReturn extends StrictElement {
  render() {
    const duration = this.attr("waiting") === "true" ? "等待接通" : this.attr("duration", "00:00");
    const root = button("c-call-return", `返回通话 ${this.attr("name", "通话")} ${duration}`, "call:return");
    const avatar = document.createElement("app-avatar");
    avatar.setAttribute("name", this.attr("name", "通话"));
    avatar.setAttribute("size", "conversation");
    if (this.attr("image")) avatar.setAttribute("image", this.attr("image"));
    const caption = element("div", "c-call-return__caption");
    caption.append(icon(this.attr("video") === "true" ? "video" : "call"), element("span", "", duration));
    root.append(avatar, caption);
    return root;
  }
}
