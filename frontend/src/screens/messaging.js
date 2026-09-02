import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";

function conversationTile(conversation, options = {}) {
  const tile = element("article", "c-conversation-row");
  if (options.pinned) tile.dataset.pinned = "true";
  const avatar = component("app-avatar", { name: conversation.name, size: "conversation", badge: options.unread ?? conversation.unread });
  const body = element("div", "c-conversation-row__body");
  body.append(element("h2", "c-conversation-row__title", conversation.name), element("p", "c-conversation-row__preview", conversation.preview));
  const meta = element("div", "c-conversation-row__meta");
  meta.append(element("time", "c-conversation-row__time", conversation.time));
  if (options.muted) meta.append(element("span", "c-conversation-row__muted", "静音"));
  tile.append(avatar, body, meta);
  tile.dataset.action = "open:chat-room-mixed";
  return tile;
}

function messageInbox(definition) {
  const root = pageRoot(definition);
  root.append(navigation("消息", { action: "更多" }));
  const content = element("div", "p-messages-inbox__content");
  if (["offline", "reconnecting"].includes(definition.state)) {
    content.append(component("app-network-capsule", { state: definition.state }));
  }
  if (definition.state === "empty") {
    content.append(component("app-empty-state", { title: "暂无会话", message: "从通讯录选择好友开始加密聊天", action: "打开通讯录" }));
  } else if (definition.state === "sync-failed") {
    content.append(component("app-empty-state", { kind: "network", title: "同步失败", message: "无法获取最新会话，请检查网络", action: "重新同步" }));
  } else {
    for (const conversation of fixtures.conversations) content.append(conversationTile(conversation));
    if (definition.state === "syncing") content.prepend(component("app-status-chip", { status: "processing", label: "正在同步端到端加密会话" }));
  }
  root.append(content, tabBar("messages"));
  return root;
}

function conversationVariant(definition) {
  const root = pageRoot(definition);
  root.append(navigation("会话状态"));
  const content = element("div", "p-messages-inbox__content");
  const base = definition.state === "group" ? fixtures.conversations[1] : definition.state === "support" ? fixtures.conversations[2] : fixtures.conversations[0];
  content.append(conversationTile(base, {
    pinned: definition.state === "pinned",
    muted: definition.state === "muted",
    unread: definition.state === "unread-max" ? "120" : definition.state === "unread-one" ? "1" : base.unread
  }));
  root.append(content, tabBar("messages"));
  return root;
}

function chatContent(definition) {
  const content = element("div", "p-chat-room__messages");
  if (definition.page === "voice") {
    content.append(component("app-voice-bubble", { duration: definition.state === "limit" ? "60" : "8", playback: definition.state === "preview" ? "playing" : "idle" }));
    content.append(component("app-toast", { kind: definition.state === "too-short" ? "warning" : "info", message: definition.state === "too-short" ? "录音不足 1 秒，未发送" : `语音状态：${definition.title}` }));
  } else if (definition.page === "attachment") {
    if (definition.state === "permission-denied") {
      content.append(component("app-empty-state", { kind: "permission", title: "无法访问照片或文件", message: "请允许畅聊访问所选内容", action: "打开系统设置" }));
    } else {
      content.append(component("app-attachment-tile", {
        state: definition.state === "upload-failed" || definition.state === "retry" ? "failed" : definition.state === "uploading" ? "uploading" : "sent",
        progress: definition.state === "uploading" ? "48" : "100",
        name: definition.state === "image-picker" ? "海边照片.webp" : "项目说明.pdf"
      }));
      if (["unsupported", "oversize"].includes(definition.state)) content.append(component("app-toast", { kind: "error", message: definition.state === "unsupported" ? "不支持此文件格式" : "文件超过允许大小" }));
    }
  } else if (definition.page === "redpacket") {
    content.append(component("app-red-packet-card", { state: definition.state, greeting: "周末愉快" }));
  } else if (definition.page === "transfer") {
    const statusLabels = { pending: "待收款 · 点击卡片收款", accepted: "已收款", returned: "已退回" };
    const card = element("div", "c-transfer-card");
    const body = element("div", "c-transfer-card__body");
    body.append(
      element("p", "c-transfer-card__amount", "200.00 点钻"),
      element("p", "c-transfer-card__status", statusLabels[definition.state] ?? statusLabels.pending)
    );
    card.append(body, element("footer", "c-transfer-card__footer", "畅聊点钻转账"));
    content.append(card);
    if (definition.state === "insufficient") content.append(component("app-toast", { kind: "error", message: "转账失败，账户余额不足" }));
  } else if (definition.page === "composer") {
    content.append(component("app-empty-state", { title: "输入区状态", message: definition.title }));
  } else if (definition.page === "details") {
    content.append(component("app-identity-header", { name: "周然", username: "zhouran", signature: "端到端加密会话" }));
  } else if (definition.state === "empty") {
    content.append(component("app-empty-state", { title: "暂无消息", message: "发送第一条端到端加密消息" }));
  } else if (definition.state === "history-failed") {
    content.append(component("app-empty-state", { kind: "network", title: "历史消息加载失败", message: "本地密钥仍安全保存在设备", action: "重试" }));
  } else {
    content.append(component("app-timestamp", { label: definition.state === "cross-day" ? "2026年8月16日 09:41" : "09:41" }));
    for (const message of fixtures.messages) {
      const delivery = definition.state === "message-failed" || definition.state === "message-retry" ? "failed" : definition.state === "message-sending" ? "sending" : message.delivery;
      content.append(component("app-message-bubble", { ...message, delivery }));
    }
    if (definition.state === "message-failed") content.append(component("app-action-button", { kind: "danger", icon: "retry", label: "重新发送", action: "retry-message" }));
    if (definition.state === "redacted") content.append(element("p", "c-system-message", "你撤回了一条消息"));
    if (definition.state === "reply") content.append(element("blockquote", "c-reply-preview", "回复 周然：明天上午九点见"));
  }
  return content;
}

function chatScreen(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "details" ? "聊天详情" : "周然", { leading: "返回", action: "详情" }));
  root.append(chatContent(definition));
  if (definition.page !== "details") root.append(component("app-composer", { mode: definition.page === "voice" ? "voice" : definition.page === "attachment" ? "attachment" : "text" }));
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.module === "messages") {
    if (definition.page === "conversation") root = conversationVariant(definition);
    else if (definition.page === "network") {
      root = pageRoot(definition, [navigation("网络状态"), element("div", "p-feedback-center")]);
      root.querySelector(".p-feedback-center").append(component("app-network-capsule", { state: definition.state }));
    } else if (definition.page === "new") {
      root = pageRoot(definition, [navigation("消息"), element("div", "p-feedback-center")]);
      root.querySelector(".p-feedback-center").append(component("app-action-sheet", { title: "新建会话", options: "发起群聊,添加朋友,扫一扫" }));
    } else root = messageInbox(definition);
  } else root = chatScreen(definition);
  return createDeviceScreen(definition, root);
}
