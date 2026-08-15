import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, pageRoot } from "./shared.js";

const stateCopy = Object.freeze({
  default: "使用用户名或邮箱登录",
  filled: "账号信息已填写，可以继续",
  submitting: "正在建立安全会话…",
  "error-required": "请输入用户名和密码",
  "error-credentials": "用户名或密码不正确",
  "error-network": "网络暂时不可用，请稍后重试",
  "invitation-required": "邀请码为必填项",
  "field-errors": "请检查标记的注册信息",
  failed: "操作未完成，请保留当前内容后重试",
  completed: "账号创建完成，请验证邮箱",
  code: "输入邮件中的 6 位验证码",
  link: "也可以点击邮件中的验证链接",
  countdown: "54 秒后可重新发送",
  "resend-ready": "没有收到邮件？可以重新发送",
  verifying: "正在验证邮箱…",
  success: "邮箱验证成功",
  "code-error": "验证码不正确，请重新输入",
  expired: "验证码已过期，请重新发送",
  "resend-failed": "验证邮件发送失败，请重试",
  keyboard: "键盘出现时表单保持可滚动",
  "reduced-motion": "已按系统设置减少动态效果"
});

function field(label, placeholder, value = "", type = "text") {
  const wrapper = element("label", "c-form-field");
  wrapper.append(element("span", "c-form-field__label", label));
  const input = element("input", "c-form-field__input");
  input.type = type;
  input.placeholder = placeholder;
  input.value = value;
  wrapper.append(input);
  return wrapper;
}

function loginForm(definition) {
  const filled = definition.state === "filled" || definition.state === "submitting";
  const form = element("form", "c-auth-form");
  form.append(
    field("用户名/邮箱", "输入用户名或邮箱", filled ? fixtures.currentUser.username : ""),
    field("密码", "输入密码", filled ? "design-password" : "", "password")
  );
  const error = definition.state.startsWith("error-")
    ? element("p", "c-form-error", stateCopy[definition.state])
    : element("p", "c-form-help", "端到端加密 · 恢复密钥仅保存在设备");
  error.setAttribute("role", definition.state.startsWith("error-") ? "alert" : "note");
  form.append(error, component("app-action-button", {
    label: "登录",
    icon: "check",
    loading: definition.state === "submitting",
    action: "auth:login"
  }), component("app-action-button", {
    label: "注册账号",
    icon: "add",
    kind: "secondary",
    action: "auth:registration"
  }));
  return form;
}

function registrationForm(definition) {
  const form = element("form", "c-auth-form");
  form.append(
    field("用户名", "设置用户名"),
    field("邮箱", "name@example.invalid", "", "email"),
    field("密码", "设置密码", "", "password"),
    field("邀请码", "邀请码（必填）")
  );
  if (["invitation-required", "field-errors", "failed"].includes(definition.state)) {
    const error = element("p", "c-form-error", stateCopy[definition.state]);
    error.setAttribute("role", "alert");
    form.append(error);
  }
  form.append(component("app-action-button", {
    label: definition.state === "completed" ? "前往验证邮箱" : "创建账号",
    icon: "add",
    loading: definition.state === "submitting",
    disabled: definition.state === "invitation-required",
    action: "auth:verification"
  }));
  return form;
}

function verificationForm(definition) {
  const form = element("form", "c-auth-form");
  form.append(field("验证码", "6 位验证码", definition.state === "success" ? "246810" : "", "text"));
  const message = element("p", definition.state.includes("error") || definition.state.includes("failed") || definition.state === "expired" ? "c-form-error" : "c-form-help", stateCopy[definition.state]);
  message.setAttribute("role", message.className === "c-form-error" ? "alert" : "status");
  form.append(message, component("app-action-button", {
    label: definition.state === "success" ? "进入畅聊" : "验证邮箱",
    icon: "check",
    loading: definition.state === "verifying",
    action: "auth:complete"
  }), component("app-action-button", {
    label: definition.state === "countdown" ? "54 秒后重发" : "重新发送邮件",
    icon: "retry",
    kind: "secondary",
    disabled: definition.state === "countdown",
    action: "auth:resend"
  }));
  return form;
}

export function renderScreen(definition) {
  const root = pageRoot(definition);
  root.classList.add("p-auth");
  const background = element("img", "p-auth__background");
  background.src = "/assets/landing.png";
  background.alt = "";
  const panel = element("section", "p-auth__panel");
  const mark = element("div", "c-brand-mark", "畅");
  mark.setAttribute("aria-hidden", "true");
  const title = definition.page === "login" ? "畅聊" : definition.page === "registration" ? "创建畅聊账号" : definition.page === "verification" ? "验证邮箱" : "畅聊认证体验";
  panel.append(mark, element("h1", "p-auth__title", title), element("p", "p-auth__subtitle", stateCopy[definition.state] ?? "安全、私密的加密通信与资产服务"));
  if (definition.page === "login") panel.append(loginForm(definition));
  else if (definition.page === "registration") panel.append(registrationForm(definition));
  else if (definition.page === "verification") panel.append(verificationForm(definition));
  else panel.append(component("app-empty-state", { title: "认证布局检查", message: stateCopy[definition.state], action: "返回登录" }));
  root.append(background, panel);
  return createDeviceScreen(definition, root);
}
