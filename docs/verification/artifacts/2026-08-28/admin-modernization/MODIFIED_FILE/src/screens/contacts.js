import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";

function contactRow(contact, trailing = "") {
  const row = element("article", "c-contact-row");
  row.append(component("app-avatar", { name: contact.name, size: "message" }));
  const body = element("div", "c-contact-row__body");
  body.append(element("h2", "c-contact-row__name", contact.name), element("p", "c-contact-row__subtitle", contact.subtitle));
  row.append(body, element("span", "c-contact-row__trailing", trailing));
  row.dataset.action = "open:friend-profile-default";
  return row;
}

function contactIndex(definition) {
  const root = pageRoot(definition);
  root.append(navigation("通讯录", { action: "添加朋友" }));
  const layout = element("div", "p-contacts-index__layout");
  const content = element("div", "p-contacts-index__content");
  const shortcuts = [
    ["新的朋友", "add"], ["群聊", "chat"], ["标签", "contact"], ["公众号 / 官方客服", "info"]
  ];
  for (const [title, leading] of shortcuts) content.append(component("app-list-tile", { title, leading, action: `contacts:${title}` }));
  for (const contact of fixtures.contacts) {
    content.append(element("h2", "c-contact-section-title", contact.name.slice(0, 1)), contactRow(contact));
  }
  layout.append(content, component("app-contact-index", { active: definition.state === "overlay" ? "Z" : "L" }));
  if (definition.state === "overlay") layout.append(element("div", "c-contact-index-overlay", "Z"));
  root.append(layout, tabBar("contacts"));
  return root;
}

function contactCollection(definition) {
  const titles = {
    friends: "新的朋友", request: "好友申请", groups: "群聊", tags: "标签",
    official: "公众号 / 官方客服", search: "搜索通讯录", state: "通讯录"
  };
  const root = pageRoot(definition);
  root.append(navigation(titles[definition.page] ?? "通讯录", { leading: "返回" }));
  const content = element("div", "p-contacts-collection__content");
  if (definition.state === "empty" || definition.state === "no-result") {
    content.append(component("app-empty-state", { title: "暂无结果", message: definition.title, action: "返回" }));
  } else if (definition.state.includes("failed") || definition.state.includes("error")) {
    content.append(component("app-empty-state", { kind: "network", title: "加载失败", message: "请检查网络后重试", action: "重试" }));
  } else if (definition.page === "request") {
    const labels = { pending: "接受", accepting: "处理中", rejected: "已拒绝", added: "已添加", failed: "重试" };
    for (const contact of fixtures.contacts.slice(0, 2)) content.append(contactRow(contact, labels[definition.state] ?? "接受"));
  } else if (definition.page === "search") {
    const search = element("label", "c-search-field");
    search.append(element("span", "u-visually-hidden", "搜索联系人"), element("input", "c-search-field__input"));
    search.querySelector("input").placeholder = "搜索联系人、群聊或标签";
    content.append(search);
    if (definition.state === "results") content.append(contactRow(fixtures.contacts[0]));
  } else {
    for (const contact of fixtures.contacts) content.append(contactRow(contact, definition.page === "official" ? "已认证" : ""));
  }
  root.append(content);
  return root;
}

function friendProfile(definition) {
  const root = pageRoot(definition);
  root.append(navigation("好友资料", { leading: "返回", action: "更多" }));
  const content = element("div", "p-friend-profile__content");
  const contact = definition.state === "support" ? fixtures.contacts[2] : fixtures.contacts[0];
  content.append(component("app-identity-header", { name: contact.name, username: contact.username, signature: contact.subtitle }));
  const preview = element("section", "c-profile-preview");
  preview.append(element("h2", "c-profile-preview__title", "朋友圈"), element("div", "c-profile-preview__images"));
  for (let index = 0; index < 3; index += 1) preview.querySelector(".c-profile-preview__images").append(element("span", "c-profile-preview__image", `动态 ${index + 1}`));
  content.append(preview);
  const actions = element("div", "c-profile-actions");
  actions.append(
    component("app-action-button", { icon: "chat", label: "发消息", action: "friend:message" }),
    component("app-action-button", { icon: "call", label: "语音通话", action: "friend:voice" }),
    component("app-action-button", { icon: "camera", label: "视频通话", action: "friend:video" })
  );
  content.append(actions);
  root.append(content);
  return root;
}

function friendSettings(definition) {
  const root = pageRoot(definition);
  root.append(navigation("好友设置", { leading: "返回" }));
  const content = element("div", "p-friend-settings__content");
  const items = [
    ["备注", "当前：周然"], ["标签", "徒步好友"], ["朋友圈权限", "好友可见"],
    ["黑名单", definition.page === "blacklist" && definition.state === "added" ? "已开启" : "未开启"], ["删除好友", ""]
  ];
  for (const [title, trailing] of items) content.append(component("app-list-tile", { title, trailing, leading: title === "删除好友" ? "error" : "info", action: `friend-setting:${title}` }));
  root.append(content);
  if (definition.page === "privacy") root.append(component("app-action-sheet", { title: "朋友圈权限", options: "允许他看,不让他看,屏蔽他的朋友圈", selected: "允许他看" }));
  if (definition.page === "delete" && definition.state === "confirm") root.append(component("app-dialog", { kind: "danger", title: "删除好友", message: "删除后将无法直接查看对方朋友圈。", cancel: "取消", confirm: "删除" }));
  if (definition.page === "blacklist" && definition.state === "add-confirm") root.append(component("app-dialog", { kind: "danger", title: "加入黑名单", message: "对方将无法向你发送消息。", cancel: "取消", confirm: "加入" }));
  if (["saved", "added", "success"].includes(definition.state)) root.append(component("app-toast", { kind: "success", message: "设置已保存" }));
  if (definition.state === "failed") root.append(component("app-toast", { kind: "error", message: "操作失败，请重试" }));
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.module === "contacts") root = definition.page === "index" ? contactIndex(definition) : contactCollection(definition);
  else if (definition.page === "profile") root = friendProfile(definition);
  else if (definition.page === "message") {
    root = pageRoot(definition, [navigation("打开加密会话", { leading: "返回" }), element("div", "p-feedback-center")]);
    root.querySelector(".p-feedback-center").append(component("app-empty-state", { kind: definition.state === "failed" ? "network" : "empty", title: definition.state === "failed" ? "无法打开会话" : "正在创建加密会话", message: definition.state === "failed" ? "请检查网络后重试" : "请稍候，不要重复点击", action: definition.state === "failed" ? "重试" : undefined }));
  } else root = friendSettings(definition);
  return createDeviceScreen(definition, root);
}
