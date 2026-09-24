import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";

const visibleCharacters = value => [...new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(value)].map(item => item.segment);

function limitDialog(root, message) {
  root.querySelector(".u-profile-limit-dialog")?.remove();
  const wrapper = element("div", "u-profile-limit-dialog");
  wrapper.append(component("app-dialog", { kind: "error", title: "输入已达上限", message, confirm: "知道了", "hide-cancel": "true" }));
  wrapper.addEventListener("click", event => {
    if (event.target.closest('[data-action="dialog-confirm"]')) wrapper.remove();
  });
  root.append(wrapper);
}

function editField(root, title, value, max) {
  const field = element("label", "c-profile-edit-field");
  const input = element("input", "c-profile-edit-field__input");
  const count = element("span", "c-profile-edit-field__count");
  input.value = value;
  input.setAttribute("aria-label", title);
  const message = `${title}最多支持${max}个字符`;
  let composing = false;
  const enforce = () => {
    const segments = visibleCharacters(input.value);
    if (segments.length > max) {
      input.value = segments.slice(0, max).join("");
      limitDialog(root, message);
    }
    count.textContent = `${visibleCharacters(input.value).length}/${max}`;
  };
  input.addEventListener("compositionstart", () => { composing = true; });
  input.addEventListener("compositionend", () => { composing = false; enforce(); });
  input.addEventListener("input", () => { if (!composing) enforce(); });
  field.append(element("span", "c-profile-edit-field__label", title), input, count);
  enforce();
  return { field, input, max, message };
}

function profileHome(definition) {
  const root = pageRoot(definition);
  root.append(navigation("我"));
  const content = element("div", "p-profile-home__content");
  if (["cached-offline", "no-cache-offline"].includes(definition.state)) {
    content.append(component("app-network-capsule", { state: "offline" }));
  }
  if (definition.state === "no-cache-offline") {
    content.append(component("app-empty-state", {
      title: "本机没有已保存的资料",
      message: "联网后将更新你的资料"
    }));
    content.append(component("app-action-button", {
      icon: "retry",
      label: "重试资料",
      action: "profile:retry"
    }));
  } else {
    content.append(component("app-identity-header", {
      name: fixtures.currentUser.name,
      username: fixtures.currentUser.username,
      signature: fixtures.currentUser.signature
    }));
  }
  content.append(component("app-list-tile", { title: "个人信息", leading: "me", action: "open:profile-details-default" }));
  for (const [title, leading, action] of [
    ["朋友圈", "camera", "open:moments-personal-default"],
    ["点钻", "gift", "open:caibi-home-default"],
    ["钱包", "wallet", "open:wallet-home-default"],
    ["设置", "info", "open:profile-settings-default"]
  ]) content.append(component("app-list-tile", { title, leading, action, trailing: title === "朋友圈" ? "2 条新互动" : undefined }));
  root.append(content, tabBar("profile"));
  return root;
}

function profileDetails(definition) {
  const root = pageRoot(definition);
  const editing = ["edit", "nickname-limit", "signature-limit"].includes(definition.state);
  root.append(navigation(editing ? "编辑资料" : "个人资料", { leading: "返回", action: editing ? "保存" : "编辑" }));
  const content = element("div", "p-profile-details__content");
  content.append(component("app-identity-header", {
    name: fixtures.currentUser.name,
    username: fixtures.currentUser.username,
    signature: fixtures.currentUser.signature
  }));
  content.append(component("app-list-tile", { title: "头像", trailing: "点击修改", leading: "me", action: "open:profile-avatar-picker" }));
  let nickname;
  let signature;
  if (editing) {
    nickname = editField(root, "昵称", definition.state === "nickname-limit" ? "👨‍👩‍👧‍👦".repeat(12) : fixtures.currentUser.name, 12);
    signature = editField(root, "个性签名", definition.state === "signature-limit" ? "👩🏽‍❤️‍💋‍👨🏻".repeat(20) : fixtures.currentUser.signature, 20);
    content.append(nickname.field, signature.field);
  } else {
    for (const [title, trailing] of [["昵称", fixtures.currentUser.name], ["个性签名", fixtures.currentUser.signature]]) content.append(component("app-list-tile", { title, trailing, leading: "me" }));
  }
  for (const [title, trailing] of [["畅聊号", fixtures.currentUser.username], ["邮箱", fixtures.currentUser.email]]) content.append(component("app-list-tile", { title, trailing, leading: "me" }));
  content.append(component("app-list-tile", { title: "邀请码", trailing: "邀请历史", leading: "gift", action: "open:profile-invitation-history" }));
  if (editing) {
    const save = component("app-action-button", { icon: "check", label: "保存资料", action: "profile:save" });
    save.addEventListener("click", () => {
      for (const field of [nickname, signature]) {
        if (visibleCharacters(field.input.value.trim()).length > field.max) {
          limitDialog(root, field.message);
          return;
        }
      }
      root.append(component("app-toast", { kind: "success", message: "资料已保存" }));
    });
    content.append(save);
  }
  root.append(content);
  if (definition.state === "nickname-limit") limitDialog(root, "昵称最多支持12个字符");
  if (definition.state === "signature-limit") limitDialog(root, "个性签名最多支持20个字符");
  return root;
}

function invitation(definition) {
  const root = pageRoot(definition);
  root.append(navigation("邀请码", { leading: "返回" }));
  const content = element("div", "p-profile-invitation__content");
  content.append(element("h2", "p-profile-invitation__heading", "我的邀请码"),
    element("div", "p-profile-invitation__code", "CF-DEMO-2026"),
    element("h2", "p-profile-invitation__heading", "邀请历史"));
  if (definition.state === "empty") content.append(component("app-empty-state", { title: "暂无邀请记录", message: "好友使用你的邀请码注册后会显示在这里" }));
  else if (definition.state === "loading") content.append(component("app-status-chip", { status: "processing", label: "正在加载邀请历史" }));
  else if (definition.state === "error") content.append(component("app-empty-state", { kind: "network", title: "邀请历史加载失败", message: "请检查网络后重试", action: "重试" }));
  else {
    const rows = [
      ["周然", "zhouran", "2026-09-24 08:12"],
      ["陈默", "chenmo", "2026-09-23 19:40"],
      ...(definition.state === "more" ? [["唐宁", "tangning", "2026-09-21 13:05"]] : []),
    ];
    for (const [name, username, time] of rows) content.append(component("app-list-tile", { title: name, subtitle: time, trailing: `畅聊号：${username}`, leading: "me" }));
    if (definition.state === "history") content.append(component("app-action-button", { label: "加载更多", icon: "more", action: "open:profile-invitation-more" }));
  }
  root.append(content);
  return root;
}

function avatar(definition) {
  const root = pageRoot(definition);
  if (definition.state === "crop") {
    root.append(component("app-image-editor", { state: "crop", "avatar-mode": "true" }));
    return root;
  }
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
  if (definition.state === "logout-history-choice") root.append(component("app-dialog", { kind: "history-choice" }));
  if (definition.state === "logout-failed") root.append(component("app-toast", { kind: "error", message: "退出失败，请检查网络后重试" }));
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.page === "home") root = profileHome(definition);
  else if (definition.page === "details") root = profileDetails(definition);
  else if (definition.page === "invitation") root = invitation(definition);
  else if (definition.page === "avatar") root = avatar(definition);
  else root = settings(definition);
  return createDeviceScreen(definition, root);
}
