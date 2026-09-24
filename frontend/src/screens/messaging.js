import { fixtures } from "../catalog/fixtures.js";
import { button, element } from "../components/base.js";
import { icon } from "../icons/icons.js";
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
  if (definition.page === "selection") {
    content.append(component("app-message-selection-session", { state: definition.state }));
  } else
  if (definition.page === "voice") {
    content.append(component("app-voice-bubble", { duration: definition.state === "limit" ? "60" : "8", playback: definition.state === "preview" ? "playing" : "idle" }));
    if (definition.state === "preview") {
      content.append(component("app-voice-bubble", { duration: "8", playback: "loading" }), component("app-voice-bubble", { duration: "8", playback: "failed" }));
      const options = [{ id: "voice-route", label: "听筒播放" }, { id: "reply", label: "引用" }, { id: "select", label: "多选" }, { id: "delete", label: "删除" }];
      const menu = component("app-anchored-action-menu", { options: JSON.stringify(options), "arrow-at-top": "true" });
      menu.addEventListener("click", (event) => {
        if (!event.target.closest('[data-action="voice-route"]')) return;
        options[0].label = options[0].label === "听筒播放" ? "扬声器播放" : "听筒播放";
        menu.setAttribute("options", JSON.stringify(options));
        menu.renderContract();
      });
      content.append(menu);
    }
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
    content.append(component("app-red-packet-card", { state: definition.state, greeting: "周末愉快", "viewer-claim": definition.state === "claimed", action: definition.state === "claimed" ? "open:redpacket-detail-history" : "open:redpacket-detail-available" }));
  } else if (definition.page === "transfer") {
    content.append(component("app-transfer-card", { amount: "200.00", state: definition.state === "insufficient" ? "pending" : definition.state, "viewer-role": definition.state === "accepted" ? "receiver" : "sender", action: "open:caibi-transfer-receiver-accepted" }));
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

function forwardBackground(definition) {
  const root = pageRoot(definition);
  root.dataset.demoSource = "local-fixture";
  const header = navigation("周然", { leading: "返回", action: "详情" });
  const content = element("div", "p-chat-room__messages p-chat-room__messages--forward");
  const composer = component("app-composer", { mode: "text" });
  const targets = Object.freeze([
    Object.freeze({ id: "zhou-ran", title: "周然" }),
    Object.freeze({ id: "weekend-group", title: "周末徒步群" })
  ]);
  const sources = Object.freeze({
    gallery: Object.freeze({ label: "视频", name: "海边日落.mp4" }),
    recording: Object.freeze({ label: "录像", name: "徒步记录.mp4" })
  });
  let source = "gallery";
  let pickerOpen = false;
  let pickerQuery = "";
  let confirmationTarget = null;
  let activeTarget = targets[0];
  let destinationView = false;
  let serial = 0;
  let pickerTargetList = null;
  const jobs = [];
  const attempts = new Map();
  const pending = new Map();

  const renderJob = job => {
    const sourceInfo = sources[job.source];
    const delivery = job.state === "sent" ? "sent" : job.state === "failed" ? "failed" : "sending";
    const stateLabel = job.state === "sent" ? "已发送" : job.state === "failed" ? "发送失败，点击重试" : "发送中";
    const item = element("section", "c-forward-job");
    item.dataset.jobId = job.id;
    item.dataset.targetId = job.target.id;
    item.dataset.state = job.state;
    item.append(
      component("app-message-bubble", {
        direction: "outgoing",
        sender: "我",
        content: `${sourceInfo.label} · ${sourceInfo.name} · ${stateLabel}`,
        delivery
      }),
      component("app-attachment-tile", {
        state: job.state === "sent" ? "sent" : job.state === "failed" ? "failed" : "uploading",
        progress: job.state === "sent" ? "100" : "",
        name: sourceInfo.name
      })
    );
    if (job.state === "failed") {
      const retry = button("c-forward-job__retry", "重试", "forward:retry");
      retry.dataset.jobId = job.id;
      retry.addEventListener("click", () => start(job));
      item.append(retry);
    }
    return item;
  };

  const renderSourceMessages = () => {
    for (const [sourceId, sourceInfo] of Object.entries(sources)) {
      const item = element("section", "c-forward-source-message");
      item.dataset.source = sourceId;
      item.append(
        component("app-message-bubble", {
          direction: "incoming",
          sender: "周然",
          content: `${sourceInfo.label} · ${sourceInfo.name}`,
          delivery: "sent"
        }),
        component("app-attachment-tile", { state: "sent", progress: "100", name: sourceInfo.name })
      );
      const forward = button("c-forward-source-message__action", "转发", "forward:open-picker");
      forward.dataset.source = sourceId;
      forward.addEventListener("click", () => {
        source = sourceId;
        pickerQuery = "";
        pickerOpen = true;
        render();
      });
      item.append(forward);
      content.append(item);
    }
  };

  const updatePickerTargets = () => {
    const targetList = pickerTargetList;
    if (!targetList) return;
    targetList.replaceChildren();
    const visibleTargets = targets.filter(target => target.title.includes(pickerQuery.trim()));
    if (!visibleTargets.length) {
      targetList.append(element("p", "c-forward-picker__empty", "未找到聊天"));
    }
    for (const target of visibleTargets) {
      const option = button("c-forward-picker__target", target.title, "forward:target");
      option.dataset.targetId = target.id;
      option.addEventListener("click", () => {
        confirmationTarget = target;
        render();
      });
      targetList.append(option);
    }
  };

  const renderPicker = () => {
    if (!pickerOpen) return;
    const picker = element("section", "c-forward-picker");
    picker.dataset.testid = "forward-picker";
    picker.append(element("h2", "c-forward-picker__title", "选择聊天"));
    const search = element("input", "c-forward-picker__search");
    search.type = "search";
    search.placeholder = "搜索";
    search.setAttribute("aria-label", "搜索聊天");
    search.value = pickerQuery;
    search.addEventListener("input", () => {
      pickerQuery = search.value;
      updatePickerTargets();
    });
    pickerTargetList = element("div", "c-forward-picker__targets");
    picker.append(
      search,
      element("p", "c-forward-picker__section", "最近聊天"),
      pickerTargetList
    );
    content.append(picker);
    updatePickerTargets();
    if (!confirmationTarget) return;
    const confirmation = element("section", "c-forward-confirmation");
    confirmation.dataset.testid = "forward-confirmation";
    confirmation.append(
      element("p", "c-forward-confirmation__label", `发送给：${confirmationTarget.title}`),
      element("p", "c-forward-confirmation__preview", `${sources[source].label} · ${sources[source].name}`)
    );
    const cancel = button("c-forward-confirmation__cancel", "取消", "forward:cancel");
    cancel.addEventListener("click", () => {
      confirmationTarget = null;
      render();
    });
    const confirm = button("c-forward-confirmation__confirm", "确认", "forward:confirm");
    confirm.addEventListener("click", () => enqueue(confirmationTarget));
    confirmation.append(cancel, confirm);
    content.append(confirmation);
  };

  const render = () => {
    content.replaceChildren();
    pickerTargetList = null;
    header.setAttribute("title", destinationView ? activeTarget.title : "周然");
    header.renderContract();
    header.querySelector('[data-action="back"]')?.addEventListener("click", () => {
      destinationView = false;
      pickerOpen = false;
      confirmationTarget = null;
      render();
    });
    content.append(component("app-timestamp", { label: "09:41" }));
    if (destinationView) {
      for (const job of jobs.filter(item => item.target.id === activeTarget.id)) content.append(renderJob(job));
    } else {
      renderSourceMessages();
    }
    renderPicker();
  };

  const settle = (job, state) => {
    if (job.state !== "sending") return;
    job.state = state;
    pending.delete(job.id);
    render();
  };

  const hold = job => {
    const request = new Promise((resolve, reject) => {
      pending.set(job.id, { resolve, reject });
    });
    request.then(
      () => settle(job, "sent"),
      () => settle(job, "failed")
    );
  };

  const start = job => {
    if (job.state === "sent") return;
    job.state = "sending";
    attempts.set(job.id, (attempts.get(job.id) ?? 0) + 1);
    hold(job);
    render();
  };

  const enqueue = target => {
    const job = { id: `forward-${++serial}`, source, target, state: "sending" };
    jobs.push(job);
    activeTarget = target;
    destinationView = true;
    pickerOpen = false;
    confirmationTarget = null;
    attempts.set(job.id, 1);
    hold(job);
    render();
  };

  const demo = {
    resolve(jobId) { pending.get(jobId)?.resolve(); },
    reject(jobId) { pending.get(jobId)?.reject(); },
    attempts(jobId) { return attempts.get(jobId) ?? 0; },
    jobs() { return jobs.map(job => ({ id: job.id, targetId: job.target.id, state: job.state })); }
  };
  root.__chatForwardDemo = demo;
  window.__chatForwardDemo = demo;

  root.append(header, content, composer);
  render();
  return root;
}

function announcementScreen(definition) {
  const root = pageRoot(definition, [navigation("群公告")]);
  const content = element("div", "p-messages-inbox__content");
  content.style.padding = "var(--space-lg)";
  content.style.display = "grid";
  content.style.gap = "var(--space-lg)";
  content.style.lineHeight = "1.6";
  function showDocument() {
    const image = element("img");
    image.src = "/assets/download-qr.png";
    image.alt = "群公告示例图片";
    image.style.maxWidth = "100%";
    image.style.objectFit = "contain";
    content.replaceChildren(element("p", "", "群主小林 · 2026-09-23 20:00"),
      element("p", "", "欢迎加入畅聊，请查看以下图片。"), image,
      element("p", "", "图片后的公告文字保持顺序显示。"));
  }
  if (definition.state === "decrypting") {
    const retry = button("c-button", "公告正在解密，点击重试");
    retry.textContent = "公告正在解密，点击重试";
    retry.addEventListener("click", showDocument);
    content.append(retry);
  } else if (definition.state === "malformed") {
    content.append(element("p", "", "公告格式异常，暂无法显示"));
  } else showDocument();
  root.append(content);
  return root;
}

function announcementNotice(definition) {
  const root = pageRoot(definition);
  root.append(navigation("周末徒步群", { leading: "返回", action: "详情" }));
  const content = element("div", "p-chat-announcement__conversation");
  const announcementId = definition.state === "new-notice" ? "weekend-20260925" : "weekend-20260924";
  const dismissalKey = "chatflow-demo-dismissed-group-announcement";
  let dismissedId = "";
  try { dismissedId = window.localStorage.getItem(dismissalKey) ?? ""; } catch { /* Embedded demos may disable storage. */ }
  if (definition.state !== "dismissed" && dismissedId !== announcementId) {
    const banner = element("div", "c-announcement-notice");
    banner.dataset.announcementId = announcementId;
    banner.append(icon("speaker", "c-announcement-notice__icon"));
    const preview = element("span", "c-announcement-notice__preview", definition.state === "new-notice"
      ? "新公告：周日徒步集合时间改为 08:30"
      : "群公告：欢迎加入周末徒步群，请查看集合安排");
    const dismiss = button("c-announcement-notice__dismiss", "不再提醒", "announcement:dismiss");
    dismiss.title = "不再提醒";
    dismiss.append(icon("close"));
    dismiss.addEventListener("click", () => {
      try { window.localStorage.setItem(dismissalKey, announcementId); } catch { /* Keep this view dismissible. */ }
      banner.remove();
    });
    banner.append(preview, dismiss);
    content.append(banner);
  }
  content.append(component("app-timestamp", { label: "今天 09:41" }),
    component("app-message-bubble", { direction: "incoming", sender: "林晓", content: "明天见，记得带水。", delivery: "sent" }));
  root.append(content, component("app-composer", { mode: "text" }));
  return root;
}

function announcementEditor(definition) {
  const root = pageRoot(definition);
  root.append(navigation("编辑群公告", { leading: "取消", action: "完成" }));
  const content = element("div", "p-chat-announcement__editor");
  const body = element("textarea", "c-announcement-editor__body");
  body.rows = 10;
  body.setAttribute("aria-label", "群公告正文");
  body.placeholder = "输入群公告";
  body.value = "欢迎加入周末徒步群！\n周日早上八点在公园东门集合。";
  const toolbar = element("div", "c-announcement-editor__toolbar");
  const addImage = button("c-announcement-editor__image", "添加图片", "open:chat-announcement-album");
  addImage.title = "添加图片";
  addImage.append(icon("image"));
  toolbar.append(addImage);
  content.append(body, toolbar, element("p", "c-announcement-editor__hint", "群公告发布后将提醒群成员"));
  root.append(content);
  return root;
}

function announcementAlbum(definition) {
  const root = pageRoot(definition);
  root.append(navigation("相册", { leading: "取消", action: "完成" }));
  const content = element("div", "p-chat-announcement__album");
  const grid = element("div", "c-announcement-album__grid");
  for (const [index, title] of ["山间晨光", "集合地点", "路线地图"].entries()) {
    const picture = button("c-announcement-album__item", title, "announcement:select-image");
    picture.dataset.mediaType = "image";
    picture.dataset.tone = String(index + 1);
    picture.append(icon("image"), element("span", "u-visually-hidden", title));
    picture.addEventListener("click", () => {
      for (const item of grid.children) item.setAttribute("aria-pressed", String(item === picture));
    });
    grid.append(picture);
  }
  content.append(element("p", "c-announcement-album__caption", "照片"), grid);
  root.append(content);
  return root;
}

function groupInfo(definition) {
  const root = pageRoot(definition);
  root.append(navigation("聊天信息", { leading: "返回" }));
  const content = element("div", "p-chat-group-info__content");
  const row = element("label", "c-group-name-row");
  const name = element("input", "c-group-name-row__input");
  name.type = "text";
  name.value = "周末徒步群";
  name.setAttribute("aria-label", "群聊名称");
  const segmenter = new Intl.Segmenter("zh", { granularity: "grapheme" });
  const graphemes = value => Array.from(segmenter.segment(value), part => part.segment);
  const count = element("span", "c-group-name-row__count", `${graphemes(name.value).length}/12`);
  let composing = false;
  const updateName = () => {
    const parts = graphemes(name.value);
    if (!composing && parts.length > 12) name.value = parts.slice(0, 12).join("");
    count.textContent = `${graphemes(name.value).length}/12`;
  };
  name.addEventListener("compositionstart", () => { composing = true; });
  name.addEventListener("compositionend", () => { composing = false; updateName(); });
  name.addEventListener("input", updateName);
  row.append(element("span", "c-group-name-row__label", "群聊名称"), name, count);
  content.append(row,
    component("app-list-tile", { title: "群公告", trailing: "查看", leading: "speaker", action: "open:chat-announcement-notice" }),
    component("app-list-tile", { title: "群管理", trailing: "›", leading: "group", action: "open:chat-group-management-owner" }));
  root.append(content);
  return root;
}

function groupManagement(definition) {
  const root = pageRoot(definition);
  root.append(navigation("群管理", { leading: "返回" }));
  const content = element("div", "p-chat-group-management__content");
  content.append(component("app-list-tile", {
    title: "群主转让", trailing: "›", leading: "group", action: "open:chat-group-management-transfer-confirm"
  }));
  const dissolve = button("c-group-management__dissolve", "解散该群聊", "open:chat-group-management-dissolve-confirm");
  dissolve.textContent = "解散该群聊";
  content.append(dissolve);
  root.append(content);
  if (definition.state === "transfer-confirm") root.append(component("app-dialog", {
    kind: "confirm", title: "转让群主", message: "请选择新群主并确认转让。", cancel: "取消", confirm: "选择成员"
  }));
  if (definition.state === "dissolve-confirm") root.append(component("app-dialog", {
    kind: "danger", title: "解散该群聊？", message: "解散后，所有群成员将退出此群。", cancel: "取消", confirm: "解散"
  }));
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.page === "announcement") {
    root = ["notice", "dismissed", "new-notice"].includes(definition.state)
      ? announcementNotice(definition)
      : definition.state === "editor" ? announcementEditor(definition)
        : definition.state === "album" ? announcementAlbum(definition)
          : announcementScreen(definition);
  } else if (definition.page === "group-info") {
    root = groupInfo(definition);
  } else if (definition.page === "group-management") {
    root = groupManagement(definition);
  } else if (definition.page === "image-editor") {
    root = pageRoot(definition, [component("app-image-editor", { state: definition.state })]);
  } else if (definition.page === "image-gallery") {
    root = pageRoot(definition, [component("app-room-image-gallery")]);
  } else if (definition.module === "messages") {
    if (definition.page === "conversation") root = conversationVariant(definition);
    else if (definition.page === "network") {
      root = pageRoot(definition, [navigation("网络状态"), element("div", "p-feedback-center")]);
      root.querySelector(".p-feedback-center").append(component("app-network-capsule", { state: definition.state }));
    } else if (definition.page === "new") {
      root = pageRoot(definition, [navigation("消息"), element("div", "p-feedback-center")]);
      root.querySelector(".p-feedback-center").append(component("app-action-sheet", { title: "新建会话", options: "发起群聊,添加朋友,扫一扫", variant: "fit" }));
    } else root = messageInbox(definition);
  } else if (definition.page === "forward") root = forwardBackground(definition);
  else root = chatScreen(definition);
  return createDeviceScreen(definition, root);
}
