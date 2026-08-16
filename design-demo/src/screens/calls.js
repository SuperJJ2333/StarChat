import { element } from "../components/base.js";
import { component, createDeviceScreen, pageRoot } from "./shared.js";

const callCopy = Object.freeze({
  calling: "正在等待对方接听…",
  incoming: "畅聊加密来电",
  connected: "00:42 · 端到端加密",
  "weak-network": "网络不稳定，正在优化连接",
  ended: "通话已结束",
  "camera-off": "摄像头已关闭",
  "microphone-off": "麦克风已关闭",
  "camera-switch": "已切换前置摄像头",
  request: "需要相机和麦克风权限",
  denied: "未获得通话权限",
  settings: "请前往系统设置开启权限",
  busy: "对方忙线中",
  "no-answer": "对方暂时无人接听",
  "connection-failed": "无法建立加密连接",
  disconnected: "网络连接已中断",
  reconnecting: "正在恢复加密通话"
});

export function renderScreen(definition) {
  const root = pageRoot(definition);
  root.classList.add("p-call");
  const hero = element("section", "p-call__hero");
  hero.append(component("app-avatar", { name: "周然", size: "detail" }), element("h1", "p-call__title", definition.page === "video" ? "周然 · 视频通话" : "周然 · 语音通话"), element("p", "p-call__status", callCopy[definition.state] ?? definition.title));
  const controls = element("div", "p-call__controls");
  controls.append(
    component("app-action-button", { kind: "navigation", icon: "microphone", label: "麦克风", action: "call:microphone" }),
    component("app-action-button", { kind: "danger", icon: "close", label: definition.state === "incoming" ? "拒绝" : "挂断", action: "call:end" }),
    component("app-action-button", { kind: "navigation", icon: definition.page === "video" ? "camera" : "call", label: definition.page === "video" ? "摄像头" : "扬声器", action: "call:media" })
  );
  root.append(hero, controls);
  if (definition.state === "incoming") root.append(component("app-action-button", { icon: "call", label: "接听", action: "call:answer" }));
  if (definition.state === "permission-denied" || definition.state === "denied") {
    root.append(component("app-dialog", { kind: "error", title: "无法使用通话权限", message: "请在系统设置中允许畅聊访问相机和麦克风。", cancel: "取消", confirm: "系统设置" }));
  } else if (["busy", "no-answer", "connection-failed", "disconnected"].includes(definition.state)) {
    root.append(component("app-toast", { kind: "error", message: callCopy[definition.state] }));
  }
  return createDeviceScreen(definition, root);
}
