import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";
import { usernameEditor } from "./username-change.js";

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
  if (!["edit", "nickname-limit", "signature-limit"].includes(definition.state)) return accountProfileDetails(definition);
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

function invitationHistory(definition) {
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

function accountProfileDetails(definition) {
  const root = pageRoot(definition);
  root.append(navigation("个人信息", { leading: "返回" }));
  const content = element("div", "p-profile-details__content");
  let saved = { name: fixtures.currentUser.name, signature: fixtures.currentUser.signature, username: fixtures.currentUser.username, nudge: "未设置" };
  try { saved = { ...saved, ...JSON.parse(globalThis.localStorage?.getItem("chatflow-account-profile-demo") ?? "{}") }; } catch { /* Optional demo storage can be unavailable. */ }
  const empty = definition.state === "empty";
  for (const [title, trailing, action] of [
    ["头像", "", "open:profile-avatar-picker"],
    ["畅聊号", saved.username, "open:profile-username-default"],
    ["邮箱", "d***@example.invalid", "open:account-email-old"],
    ["手机号", "+86****0001", "open:phone-rebind-old"],
    ["昵称", empty ? "未设置" : saved.name, "open:profile-nickname-default"],
    ["个性签名", empty ? "未设置" : saved.signature || "未设置", "open:profile-signature-default"],
    ["拍一拍", saved.nudge, "open:profile-nudge-default"]
  ]) content.append(component("app-list-tile", { title, trailing, leading: "none", action, "avatar-name": title === "头像" ? saved.name : undefined }));
  content.append(element("div", "p-profile-details__secondary", "邀请好友"), component("app-list-tile", { title: "邀请码", trailing: "查看邀请信息", leading: "none", action: "open:profile-invitation-default" }));
  root.append(content);
  return root;
}

function profileFieldEditor(definition) {
  const config = { nickname: ["昵称", "name", 12], signature: ["个性签名", "signature", 20], nudge: ["拍一拍", "nudge", 10] }[definition.page];
  const [label, key, limit] = config;
  const root = pageRoot(definition);
  root.append(navigation(`修改${label}`, { leading: "返回" }));
  const content = element("div", "p-profile-details__content");
  let saved = { name: fixtures.currentUser.name, signature: fixtures.currentUser.signature, nudge: "" };
  try { saved = { ...saved, ...JSON.parse(globalThis.localStorage?.getItem("chatflow-account-profile-demo") ?? "{}") }; } catch {}
  let draft = definition.state === "empty" ? "" : saved[key];
  let failOnce = definition.state === "save-failed", busy = false, status = "";
  function draw() {
    const field = component("app-labeled-input-row", { label, value: draft, placeholder: `填写${label}`, enabled: String(!busy) });
    const save = component("app-action-button", { label: "保存资料", icon: "check", loading: busy });
    save.addEventListener("click", async () => {
      if (busy) return;
      draft = (field.value ?? field.getAttribute?.("value") ?? draft).trim();
      if (key === "name" && !draft) { status = "请输入昵称，草稿已保留"; draw(); return; }
      if (draft !== saved[key] && [...new Intl.Segmenter("zh", { granularity: "grapheme" }).segment(draft)].length > limit) { status = `${label}最多支持${limit}个字符，草稿已保留`; draw(); return; }
      busy = true; draw(); await Promise.resolve(); busy = false;
      if (failOnce) { failOnce = false; status = "保存失败，草稿已保留，请重试"; }
      else {
        saved[key] = draft; status = "资料已保存（演示）";
        try { globalThis.localStorage?.setItem("chatflow-account-profile-demo", JSON.stringify(saved)); } catch { status = "当前浏览器无法保存演示资料，请重试"; }
      }
      draw();
    });
    content.replaceChildren(field, save);
    if (status) { const message = element("p", status.includes("失败") || status.includes("请输入") ? "c-form-error" : "c-form-help", status); message.setAttribute("role", status.includes("失败") || status.includes("请输入") ? "alert" : "status"); content.append(message); }
    content.append(component("app-action-button", { label: "返回个人信息", kind: "secondary", icon: "close", action: "open:profile-details-default" }));
  }
  draw(); root.append(content); return root;
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

function invitation(definition) {
  const root = pageRoot(definition);
  root.append(navigation("邀请码", { leading: "返回" }));
  const host = element("div", "p-profile-details__content");
  host.append(element("p", "c-form-help", "DEMO2026 · 剩余可用次数：20（演示）"));
  const copy = component("app-action-button", { label: "复制邀请码", icon: "copy" });
  copy.addEventListener("click", async () => {
    try { await globalThis.navigator.clipboard.writeText("DEMO2026"); host.append(element("p", "c-form-help", "复制成功")); }
    catch { host.append(element("p", "c-form-error", "复制失败，请重试")); }
  });
  host.append(copy); root.append(host); return root;
}

function settings(definition) {
  const root = pageRoot(definition);
  root.append(navigation("设置", { leading: "返回" }));
  const content = element("div", "p-profile-settings__content");
  content.append(element("h2", "p-account__group", "账号"), component("app-list-tile", { title: "账号安全", leading: "info", action: "open:account-security-default" }), component("app-gradient-divider"), element("h2", "p-account__group", "通用"));
  for (const [title, trailing, action] of [["聊天", "", "open:account-chat-default"], ["消息通知", "已开启", null], ["减少动态效果", "跟随系统", null], ["关于畅聊", "1.1", null]]) content.append(component("app-list-tile", { title, trailing, leading: "info", action }), component("app-gradient-divider"));
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
  else if (definition.page === "username") root = usernameEditor(definition);
  else if (definition.page === "invitation") root = ["history", "more", "empty", "loading", "error"].includes(definition.state) ? invitationHistory(definition) : invitation(definition);
  else if (["nickname", "signature", "nudge"].includes(definition.page)) root = profileFieldEditor(definition);
  else if (definition.page === "avatar") root = avatar(definition);
  else root = settings(definition);
  return createDeviceScreen(definition, root);
}
