import { element, button } from "../components/base.js";
import { icon } from "../icons/icons.js";
import { component, createDeviceScreen, pageRoot } from "./shared.js";
import { peerAvatar } from "./notification-avatar.js";

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
  const video = definition.page === "video";
  const active = ["connected", "restored", "minimized", "camera-off", "microphone-off", "camera-switch", "weak-network"].includes(definition.state);
  let cameraEnabled = definition.state !== "camera-off";
  let minimized = definition.state === "minimized";
  const hero = element("section", "p-call__hero");
  hero.append(component("app-avatar", { name: "周然", size: "detail", image: peerAvatar }), element("h1", "p-call__title", video ? "周然 · 视频通话" : "周然 · 语音通话"), element("p", "p-call__status", active ? "00:42 · 端到端加密" : callCopy[definition.state] ?? definition.title));
  const preview = element("div", "p-call__local-video", "本人摄像头画面 · 示例");
  preview.dataset.control = "local-video";
  preview.hidden = !video || !cameraEnabled;
  if (video && active) hero.append(preview);
  const controls = element("div", "p-call__controls");
  controls.append(
    component("app-action-button", { kind: "navigation", icon: "microphone", label: "麦克风", action: "call:microphone" }),
    component("app-action-button", { kind: "danger", icon: "close", label: definition.state === "incoming" ? "拒绝" : "挂断", action: "call:end" }),
    component("app-action-button", { kind: "navigation", icon: video ? "camera" : "call", label: video ? "切换镜头" : "扬声器", action: "call:media" })
  );
  if (video && active) {
    const toggle = button("p-call__camera-toggle", "关闭摄像头");
    toggle.dataset.control = "camera-toggle";
    const updateCamera = () => {
      const label = cameraEnabled ? "关闭摄像头" : "开启摄像头";
      toggle.setAttribute("aria-label", label);
      toggle.setAttribute("aria-pressed", String(!cameraEnabled));
      toggle.replaceChildren(icon("video"), element("span", "", label));
      preview.hidden = !cameraEnabled;
      root.dataset.cameraEnabled = String(cameraEnabled);
    };
    toggle.addEventListener("click", () => { cameraEnabled = !cameraEnabled; updateCamera(); });
    updateCamera();
    controls.append(toggle);
  }
  root.append(hero, controls);
  if (active) {
    const minimize = button("p-call__minimize", "最小化通话");
    minimize.dataset.control = "minimize";
    minimize.textContent = "最小化";
    const mini = component("app-call-return", {name: "周然", image: peerAvatar, video: String(video), duration: "00:42"});
    mini.className = "p-call__return";
    mini.dataset.control = "return-call";
    const updateMinimized = () => {
      hero.hidden = controls.hidden = minimize.hidden = minimized;
      mini.hidden = !minimized;
    };
    minimize.addEventListener("click", () => { minimized = true; updateMinimized(); });
    mini.addEventListener("click", () => { minimized = false; updateMinimized(); });
    root.append(minimize, mini);
    updateMinimized();
  }
  if (definition.state === "incoming") root.append(component("app-action-button", { icon: "call", label: "接听", action: "call:answer" }));
  if (definition.state === "permission-denied" || definition.state === "denied") {
    root.append(component("app-dialog", { kind: "error", title: "无法使用通话权限", message: "请在系统设置中允许畅聊访问相机和麦克风。", cancel: "取消", confirm: "系统设置" }));
  } else if (["busy", "no-answer", "connection-failed", "disconnected"].includes(definition.state)) {
    root.append(component("app-toast", { kind: "error", message: callCopy[definition.state] }));
  }
  return createDeviceScreen(definition, root);
}
