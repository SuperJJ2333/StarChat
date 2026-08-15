import { componentContracts } from "../catalog/contracts.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot } from "./shared.js";

function foundation(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "tokens" ? "Foundations" : "Components"));
  const content = element("div", "p-foundation__content");
  if (definition.page === "tokens") {
    content.append(element("h2", "c-foundation-section__title", "语义色彩"));
    for (const name of ["brand-primary", "page-background", "surface-primary", "surface-elevated", "text-primary", "text-secondary", "danger", "warning", "social-link"]) {
      const row = element("article", "c-token-row");
      const swatch = element("span", `c-token-row__swatch c-token-row__swatch--${name}`);
      row.append(swatch, element("code", "c-token-row__name", `--color-${name}`));
      content.append(row);
    }
    content.append(element("h2", "c-foundation-section__title", "字体与间距"));
    for (const [name, sample] of [["Display", "1288.50 彩币"], ["Title 1", "畅聊朋友圈"], ["Body", "端到端加密消息正文"], ["Caption", "今天 09:41"]]) content.append(element("p", `c-type-sample c-type-sample--${name.toLowerCase().replace(" ", "-")}`, sample));
  } else {
    for (const contract of componentContracts) {
      const group = element("section", "c-component-sample");
      group.append(element("h2", "c-component-sample__title", contract.tagName));
      group.append(component(contract.tagName, contract.tagName === "app-navigation-bar" ? { heading: "2", title: "页面导航" } : {}));
      content.append(group);
    }
  }
  root.append(content);
  return root;
}

function feedback(definition) {
  const root = pageRoot(definition);
  root.append(navigation("全局反馈", { leading: "返回" }));
  const content = element("div", "p-feedback-center");
  if (definition.page === "dialog") content.append(component("app-dialog", { kind: definition.state, title: definition.title, message: "这是可独立审查的标准弹窗状态。", cancel: "取消", confirm: "确认" }));
  else if (definition.page === "toast") content.append(component("app-toast", { kind: definition.state, message: definition.title }));
  else if (definition.page === "empty") content.append(component("app-empty-state", { kind: definition.state === "default" || definition.state === "retry" ? "empty" : definition.state, title: definition.title, message: "状态同时使用图标和文字表达", action: definition.state === "retry" ? "重试" : undefined }));
  else if (definition.page === "loading") content.append(component("app-status-chip", { status: "processing", label: definition.title }));
  else if (definition.page === "permission") content.append(component("app-empty-state", { kind: "permission", title: "权限被拒绝", message: "请在系统设置中允许所需权限", action: "打开系统设置" }));
  else if (definition.page === "network") content.append(component("app-network-capsule", { state: definition.state === "reconnecting" ? "reconnecting" : "offline", label: definition.title }));
  else if (definition.page === "motion") content.append(component("app-empty-state", { title: "减少动态效果", message: "位移、缩放和波形动画已关闭" }));
  else {
    const sample = element("section", "c-type-scale-demo");
    sample.dataset.scale = definition.state;
    sample.append(element("h2", "c-type-scale-demo__title", "字号缩放检查"), element("p", "c-type-scale-demo__body", "长文案在系统字号变化时仍然保持完整，不裁切关键操作。"), component("app-action-button", { icon: "check", label: "确认内容可读" }));
    content.append(sample);
  }
  root.append(content);
  return root;
}

export function renderScreen(definition) {
  const root = definition.module === "foundation" ? foundation(definition) : feedback(definition);
  return createDeviceScreen(definition, root);
}
