import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";

function profileHome(definition) {
  const root = pageRoot(definition);
  root.append(navigation("我"));
  const content = element("div", "p-profile-home__content");
  content.append(component("app-identity-header", {
    name: fixtures.currentUser.name,
    username: fixtures.currentUser.username,
    signature: fixtures.currentUser.signature
  }));
  for (const [title, leading, action] of [
    ["朋友圈", "camera", "open:moments-timeline-default"],
    ["点钻", "gift", "open:caibi-home-default"],
    ["钱包", "wallet", "open:wallet-home-default"],
    ["设置", "info", "open:profile-settings-default"]
  ]) content.append(component("app-list-tile", { title, leading, action }));
  root.append(content, tabBar("profile"));
  return root;
}

function profileDetails(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.state === "edit" ? "编辑资料" : "个人资料", { leading: "返回", action: definition.state === "edit" ? "保存" : "编辑" }));
  const content = element("div", "p-profile-details__content");
  content.append(component("app-identity-header", {
    name: fixtures.currentUser.name,
    username: fixtures.currentUser.username,
    signature: fixtures.currentUser.signature
  }));
  for (const [title, trailing] of [["头像", "点击修改"], ["昵称", fixtures.currentUser.name], ["畅聊号", fixtures.currentUser.username], ["个性签名", fixtures.currentUser.signature], ["邮箱", fixtures.currentUser.email]]) content.append(component("app-list-tile", { title, trailing, leading: "me" }));
  if (definition.state === "edit") content.append(component("app-action-button", { icon: "check", label: "保存资料", action: "profile:save" }));
  root.append(content);
  return root;
}

function avatar(definition) {
  const root = pageRoot(definition);
  root.append(navigation("修改头像", { leading: "返回" }));
  const content = element("div", "p-profile-avatar__content");
  content.append(component("app-avatar", { name: fixtures.currentUser.name, size: "detail" }), element("h2", "p-profile-avatar__title", definition.title));
  if (definition.state === "crop") content.append(element("div", "c-avatar-crop", "拖动并缩放头像"));
  else content.append(element("p", "p-profile-avatar__message", definition.state === "fallback" ? "图片加载失败，已使用默认头像" : "头像仅在设备端裁剪后上传"));
  content.append(component("app-action-button", { icon: definition.state === "upload-failed" ? "retry" : "camera", label: definition.state === "upload-failed" ? "重试上传" : definition.state === "restore-confirm" ? "恢复默认头像" : "从相册选择", kind: definition.state === "restore-confirm" ? "danger" : "primary", loading: definition.state === "uploading", action: "profile:avatar" }));
  root.append(content);
  if (definition.state === "permission-denied") root.append(component("app-dialog", { kind: "error", title: "无法访问照片", message: "请在系统设置中允许畅聊访问相册。", cancel: "取消", confirm: "系统设置" }));
  if (definition.state === "restore-confirm") root.append(component("app-dialog", { kind: "danger", title: "恢复默认头像", message: "当前头像将被默认首字头像替换。", cancel: "取消", confirm: "恢复" }));
  if (definition.state === "upload-failed") root.append(component("app-toast", { kind: "error", message: "头像上传失败，裁剪结果已保留" }));
  return root;
}

function settings(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.state === "privacy" ? "账号与隐私" : "设置", { leading: "返回" }));
  const content = element("div", "p-profile-settings__content");
  for (const [title, trailing] of [["账号与隐私", ""], ["消息通知", "已开启"], ["减少动态效果", "跟随系统"], ["关于畅聊", "1.1"]]) content.append(component("app-list-tile", { title, trailing, leading: "info" }));
  content.append(component("app-action-button", { kind: "danger", icon: "close", label: definition.state === "logout-loading" ? "正在退出…" : "退出登录", loading: definition.state === "logout-loading", action: "profile:logout" }));
  root.append(content);
  if (definition.state === "logout-confirm") root.append(component("app-dialog", { kind: "danger", title: "退出登录", message: "退出后将清除本设备的登录状态。", cancel: "取消", confirm: "退出登录" }));
  if (definition.state === "logout-failed") root.append(component("app-toast", { kind: "error", message: "退出失败，请检查网络后重试" }));
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.page === "home") root = profileHome(definition);
  else if (definition.page === "details") root = profileDetails(definition);
  else if (definition.page === "avatar") root = avatar(definition);
  else root = settings(definition);
  return createDeviceScreen(definition, root);
}
