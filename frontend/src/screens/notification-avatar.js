import { element, button } from "../components/base.js";
import { component, navigation, pageRoot } from "./shared.js";

// Local synthetic portrait fixture, never a real user or remote media request.
export const peerAvatar = "./assets/demo-peer-avatar.svg";
const groupAvatar = "./assets/demo-group-avatar.svg";

export function notificationAvatarDemo(definition) {
  const root = pageRoot(definition, [navigation("消息")]);
  const slot = element("div", "p-notification-avatar");
  const group = definition.state !== "direct";
  const show = () => {
    const banner = button("p-notification-avatar__banner", "打开会话");
    banner.dataset.notification = "visible";
    banner.append(component("app-avatar", {name: group ? "周末出游群" : "周然", image: group ? groupAvatar : peerAvatar, size: "conversation"}));
    const copy = element("div");
    copy.append(element("strong", "", group ? "周末出游群" : "周然"), element("p", "", "你收到了一条新消息"));
    banner.append(copy);
    banner.addEventListener("click", () => slot.replaceChildren(element("p", "", "已查看 · 返回桌面后不重复提醒")));
    slot.replaceChildren(banner);
  };
  if (definition.state === "viewed") slot.append(element("p", "", "已查看 · 返回桌面后不重复提醒"));
  else show();
  const fresh = button("p-notification-avatar__new", "模拟收到新消息");
  fresh.dataset.control = "new-message";
  fresh.textContent = "模拟收到新消息";
  fresh.addEventListener("click", show);
  root.append(slot, fresh);
  return root;
}
