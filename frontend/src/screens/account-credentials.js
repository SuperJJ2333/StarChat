import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot } from "./shared.js";

// Catalog simulation only: no real OTP request, credentials gateway or sensitive storage.
const demoCode = "246810";
const help = text => element("p", "c-form-help", text);
function notice(text, error = false) {
  const node = element("p", error ? "c-form-error" : "c-form-help", text);
  node.setAttribute("role", error ? "alert" : "status");
  return node;
}
function field(label, value, change, type = "text", disabled = false) {
  const root = element("label", "c-form-field");
  const input = element("input", "c-form-field__input");
  input.setAttribute("aria-label", label);
  input.type = type;
  input.disabled = disabled;
  input.value = value;
  input.autocomplete = type === "password" ? "new-password" : "off";
  if (label.includes("验证码")) { input.inputMode = "numeric"; input.maxLength = 6; }
  input.addEventListener("input", () => change(input.value));
  root.append(element("span", "c-form-field__label", label), input);
  return root;
}
function control(label, onClick, options = {}) {
  const node = component("app-action-button", { label, icon: options.icon ?? "check", ...options });
  node.addEventListener("click", async () => { if (!options.disabled && !options.loading) await onClick(); });
  return node;
}
function shell(definition, title) {
  const root = pageRoot(definition);
  root.classList.add("p-account");
  root.append(navigation(title, { leading: "返回" }));
  const host = element("div", "p-account__content");
  root.append(host);
  return { root, host };
}
const validTarget = (channel, value) => channel === "phone"
  ? /^(?:\+86)?1[3-9]\d{9}$/u.test(value.replace(/\s/gu, ""))
  : /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value);
const demoNote = () => notice("仅本地演示，不发送短信或邮件，不保存密码。演示验证码：246810");
function resendControl(root, until, onClick, options) {
  const remaining = () => Math.max(0, Math.ceil((until - Date.now()) / 1000));
  const config = { ...options, disabled: options.disabled || remaining() > 0, icon: "send" };
  const node = control(remaining() ? `${remaining()} 秒后可重发` : "获取验证码", onClick, config);
  function tick() {
    if (!root.isConnected || !node.isConnected) return;
    const seconds = remaining();
    config.disabled = options.disabled || seconds > 0;
    node.setAttribute("label", seconds ? `${seconds} 秒后可重发` : "获取验证码");
    if (config.disabled) node.setAttribute("disabled", "true"); else node.removeAttribute("disabled");
    node.renderContract?.();
    if (seconds) setTimeout(tick, 1000);
  }
  if (remaining() && typeof window !== "undefined") setTimeout(tick, 1000);
  return node;
}

function password(definition) {
  const { root, host } = shell(definition, "更换密码");
  let channel = ["phone", "bound-phone"].includes(definition.state) ? "phone" : "email";
  const singleChannel = ["bound-phone", "bound-email"].includes(definition.state);
  let target = "", code = "", newPassword = "", confirmation = "", requested = "";
  let codeUntil = 0, resendUntil = definition.state === "cooldown" ? Date.now() + 60000 : 0;
  if (definition.state === "expired") { target = "demo@example.invalid"; requested = target; codeUntil = Date.now() - 1; }
  if (definition.state === "cooldown") { target = "demo@example.invalid"; requested = target; codeUntil = Date.now() + 300000; }
  let proofUntil = ["password", "password-mismatch", "submitting"].includes(definition.state) ? Date.now() + 300000 : 0;
  let phase = definition.state === "success" ? "success" : proofUntil ? "password" : "code";
  let busy = ["verifying", "submitting"].includes(definition.state);
  let error = ({ "code-error": "验证码不正确或已过期，请重新获取", expired: "验证码不正确或已过期，请重新获取", "network-error": "网络暂时不可用，请重试", "password-mismatch": "两次输入的密码不一致" })[definition.state] ?? "";
  let status = "";
  const unbound = definition.state === "unbound";
  let failNetwork = definition.state === "network-error";
  const clearSecrets = () => { code = ""; newPassword = ""; confirmation = ""; };
  async function perform(work) {
    if (busy || unbound) return;
    busy = true; draw();
    await Promise.resolve();
    busy = false;
    if (failNetwork) { failNetwork = false; error = "网络暂时不可用，请重试"; }
    else work();
    draw();
  }
  function draw() {
    if (phase === "success") {
      clearSecrets(); proofUntil = 0;
      host.replaceChildren(element("h2", "p-account__title", "密码已更换（演示）"), help("正式客户端完成后将返回登录，本地聊天记录保留。"), component("app-action-button", { label: "返回登录", icon: "check", action: "open:auth-login-default" }), demoNote());
      return;
    }
    const nodes = [element("h2", "p-account__title", phase === "code" ? "1 · 验证已绑定的联系方式" : "2 · 设置新密码")];
    if (phase === "code") {
      const channels = element("div", "p-account__channels");
      for (const [value, label] of singleChannel ? [] : [["email", "已绑定邮箱"], ["phone", "已绑定手机号"]]) {
        const selector = control(label, () => { channel = value; target = ""; requested = ""; proofUntil = 0; error = ""; status = ""; clearSecrets(); draw(); }, { kind: "secondary", disabled: busy });
        channels.append(selector);
      }
      nodes.push(channels, help(unbound ? "当前账号没有可用的已验证绑定渠道，请联系客服帮助。" : "如账号已绑定该验证方式，验证信息将发送至相应渠道。"), field(channel === "phone" ? "已绑定手机号" : "已绑定邮箱", target, value => { target = value; requested = ""; proofUntil = 0; code = ""; }, channel === "phone" ? "tel" : "email"));
      nodes.push(resendControl(root, resendUntil, () => perform(() => {
        if (!validTarget(channel, target)) { error = "请输入正确的邮箱或中国大陆手机号"; return; }
        requested = target; codeUntil = Date.now() + 300000; resendUntil = Date.now() + 60000; code = ""; error = ""; status = "如账号已绑定该验证方式，验证码将发送至相应渠道（本地演示）。";
      }), { disabled: unbound, loading: busy }));
      nodes.push(field("验证码", code, value => { code = value; }), control("验证并继续", () => perform(() => {
        if (!requested || requested !== target) { error = "请先获取验证码"; return; }
        if (code !== demoCode || Date.now() >= codeUntil) { error = "验证码不正确或已过期，请重新获取"; return; }
        proofUntil = Date.now() + 300000; requested = ""; phase = "password"; clearSecrets(); error = ""; status = "";
      }), { disabled: unbound, loading: busy }));
    } else {
      nodes.push(help("密码长度为 12–256 位。验证码验证成功后才能提交。"), field("新密码", newPassword, value => { newPassword = value; }, "password"), field("确认密码", confirmation, value => { confirmation = value; }, "password"), control("确认更换密码", () => perform(() => {
        if (Date.now() >= proofUntil) { error = "验证已过期，请重新获取验证码"; phase = "code"; clearSecrets(); return; }
        if (newPassword.length < 12 || newPassword.length > 256) { error = "密码长度应为 12–256 位"; return; }
        if (newPassword !== confirmation) { error = "两次输入的密码不一致"; return; }
        phase = "success"; clearSecrets(); proofUntil = 0;
      }), { loading: busy }));
    }
    if (error) nodes.push(notice(error, true));
    if (status) nodes.push(notice(status));
    nodes.push(component("app-gradient-divider"), demoNote(), component("app-action-button", { label: "返回登录", icon: "close", kind: "secondary", action: "open:auth-login-default" }));
    host.replaceChildren(...nodes);
  }
  draw();
  return root;
}

function email(definition) {
  const { root, host } = shell(definition, "绑定或更换邮箱");
  let phase = definition.state === "success" ? "success" : definition.state === "new" ? "new" : "old";
  let proofUntil = phase === "new" ? Date.now() + 300000 : 0;
  let target = "", code = "", requested = "", oldRequested = false, busy = definition.state === "verifying";
  let codeUntil = 0, resendUntil = 0;
  if (definition.state === "expired") { oldRequested = true; codeUntil = Date.now() - 1; }
  let error = ["code-error", "expired"].includes(definition.state) ? "验证码不正确或已过期，请重新获取" : definition.state === "network-error" ? "网络暂时不可用，请重试" : "";
  let failNetwork = definition.state === "network-error";
  const unbound = definition.state === "unbound";
  async function run(work) {
    if (busy || unbound) return;
    busy = true; draw(); await Promise.resolve(); busy = false;
    if (failNetwork) { failNetwork = false; error = "网络暂时不可用，请重试"; } else work();
    draw();
  }
  function draw() {
    const nodes = [element("h2", "p-account__title", phase === "old" ? "1 · 验证当前联系方式" : phase === "new" ? "2 · 验证新邮箱" : "邮箱已更新（演示）")];
    if (phase === "old") {
      nodes.push(help(unbound ? "没有可用的已验证联系方式，请联系客服。" : definition.state === "phone" ? "先验证当前已绑定手机 138****0001，再绑定邮箱。" : "先验证当前已绑定邮箱 d***@example.invalid。旧邮箱不可用时请联系客服。"), resendControl(root, resendUntil, () => run(() => { oldRequested = true; codeUntil = Date.now() + 300000; resendUntil = Date.now() + 60000; code = ""; error = ""; }), { disabled: unbound, loading: busy }), field("当前验证码", code, value => { code = value; }), control("验证当前联系方式", () => run(() => {
        if (!oldRequested) { error = "请先获取验证码"; return; }
        if (code !== demoCode || Date.now() >= codeUntil) { error = "验证码不正确或已过期，请重新获取"; return; }
        proofUntil = Date.now() + 300000; oldRequested = false; phase = "new"; code = ""; resendUntil = 0; error = "";
      }), { disabled: unbound, loading: busy }));
    } else if (phase === "new") {
      nodes.push(field("新邮箱", target, value => { target = value; requested = ""; code = ""; }, "email"), resendControl(root, resendUntil, () => run(() => {
        if (Date.now() >= proofUntil) { error = "当前联系方式验证已过期，请重新验证"; phase = "old"; code = ""; return; }
        if (!validTarget("email", target)) { error = "请输入正确的邮箱"; return; }
        requested = target; codeUntil = Date.now() + 300000; resendUntil = Date.now() + 60000; code = ""; error = "";
      }), { loading: busy }), field("新邮箱验证码", code, value => { code = value; }), control("保存邮箱", () => run(() => {
        if (Date.now() >= proofUntil) { error = "当前联系方式验证已过期，请重新验证"; phase = "old"; code = ""; return; }
        if (!requested || requested !== target) { error = "请先获取验证码"; return; }
        if (code !== demoCode || Date.now() >= codeUntil) { error = "验证码不正确或已过期，请重新获取"; return; }
        phase = "success"; code = ""; target = ""; requested = ""; proofUntil = 0; error = "";
      }), { loading: busy }));
    } else nodes.push(help("已验证邮箱摘要已更新。正式客户端以业务 API 返回值为准。"));
    if (error) nodes.push(notice(error, true));
    nodes.push(component("app-gradient-divider"), demoNote(), component("app-action-button", { label: "返回账号安全", icon: "close", kind: "secondary", action: "open:account-security-default" }));
    host.replaceChildren(...nodes);
  }
  draw(); return root;
}

function security(definition) {
  const { root, host } = shell(definition, "账号安全");
  const unavailable = ["loading", "failed"].includes(definition.state);
  const unbound = definition.state === "unbound";
  const phoneBound = !unbound && definition.state !== "email-only";
  const emailBound = !unbound && definition.state !== "phone-only";
  const passwordPage = unbound ? "account-password-unbound" : !emailBound ? "account-password-bound-phone" : !phoneBound ? "account-password-bound-email" : "account-password-code";
  for (const [title, trailing, action] of [["绑定或更换手机号", phoneBound ? "138****0001" : "未绑定", unbound ? null : phoneBound ? "phone-rebind-old" : "phone-rebind-email"], ["绑定或更换邮箱", emailBound ? "d***@example.invalid" : "未绑定", unbound ? "account-email-unbound" : emailBound ? "account-email-old" : "account-email-phone"], ["更换密码", "", passwordPage]]) {
    host.append(component("app-list-tile", { title, trailing, leading: "info", action: unavailable || !action ? undefined : `open:${action}`, disabled: unavailable || !action }), component("app-gradient-divider"));
  }
  if (unbound) host.append(help("当前没有可用的已验证联系方式，绑定手机号前请联系客服帮助。"));
  if (definition.state === "loading") host.append(notice("正在读取已验证绑定状态…"));
  if (definition.state === "failed") host.append(notice("绑定状态加载失败，请重试", true), component("app-action-button", { label: "重试", icon: "retry", action: "open:account-security-default" }));
  host.append(component("app-action-button", { label: "返回设置", kind: "secondary", icon: "close", action: "open:profile-settings-default" }));
  return root;
}
function chat(definition) {
  const { root, host } = shell(definition, "聊天");
  let enabled = definition.state !== "off", busy = definition.state === "saving";
  let error = definition.state === "failed" ? "保存失败，已恢复原设置" : "";
  let failOnce = definition.state === "failed";
  function draw() {
    const toggle = element("button", "p-account__switch", "是否自动允许加入群聊");
    toggle.type = "button"; toggle.setAttribute("role", "switch"); toggle.setAttribute("aria-checked", String(enabled)); toggle.disabled = busy;
    toggle.append(element("span", "p-account__switch-status", busy ? "保存中…" : enabled ? "已开启" : "已关闭"));
    toggle.addEventListener("click", async () => {
      if (busy) return;
      const saved = enabled; enabled = !enabled; busy = true; error = ""; draw(); await Promise.resolve(); busy = false;
      if (failOnce) { failOnce = false; enabled = saved; error = "保存失败，已恢复原设置"; }
      draw();
    });
    host.replaceChildren(toggle, component("app-gradient-divider"), help("开启后，好友邀请你加入群聊时将自动加入。此处仅演示本地偏好，正式客户端由业务 API 保存。"));
    if (error) host.append(notice(error, true));
    host.append(component("app-action-button", { label: "返回设置", kind: "secondary", icon: "close", action: "open:profile-settings-default" }));
  }
  draw(); return root;
}
export function renderScreen(definition) {
  const renderer = { password, email, security, chat, recovery }[definition.page];
  return createDeviceScreen(definition, renderer(definition));
}

function recovery(definition) {
  const { root, host } = shell(definition, "聊天记录同步");
  const messages = {
    downloading: "正在恢复聊天记录", ready: "已恢复可用记录",
    partial: "部分旧记录缺少历史密钥", retrying: "网络暂不可用，稍后自动重试",
    unavailable: "恢复服务暂不可用，稍后自动重试", revoked: "已退出当前账号，同步已停止",
  };
  host.append(notice(messages[definition.state]),
    help("登录后自动同步最近 72 小时可访问的聊天记录。没有备份的旧密钥无法重建。"));
  for (const [title, value] of [["已下载密文", "80"], ["已托管密钥", "12"], ["已解密记录", "76"], ["缺少密钥", definition.state === "partial" ? "4" : "0"]]) {
    host.append(component("app-list-tile", { title, trailing: definition.state === "revoked" ? "—" : value }));
  }
  host.append(help("恢复材料由服务器加密托管，消息在设备上解密。"), help("本页数据仅用于界面演示，不连接真实恢复服务。"));
  if (["retrying", "unavailable", "partial"].includes(definition.state)) {
    host.append(component("app-action-button", { label: "重试同步", icon: "retry", action: "open:account-recovery-downloading" }));
  }
  host.append(component("app-action-button", { label: "返回设置", kind: "secondary", action: "open:profile-settings-default" }));
  return root;
}
