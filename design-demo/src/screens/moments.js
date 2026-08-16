import { fixtures } from "../catalog/fixtures.js";
import { button, element } from "../components/base.js";
import { component, createDeviceScreen, navigation, pageRoot, tabBar } from "./shared.js";

function discovery(definition) {
  const root = pageRoot(definition);
  root.append(navigation("发现"));
  const content = element("div", "p-discovery-home__content");
  if (definition.state === "loading") content.append(component("app-empty-state", { title: "正在加载", message: "正在获取发现页内容" }));
  else if (definition.state === "error-network") content.append(component("app-empty-state", { kind: "network", title: "网络异常", message: "暂时无法打开发现页", action: "重试" }));
  else {
    content.append(component("app-list-tile", { title: "朋友圈", subtitle: definition.state === "moments-new" ? "周然发布了新内容" : "查看好友动态", trailing: definition.state === "moments-new" ? "●" : "", leading: "camera", action: "open:moments-timeline-default" }));
    content.append(component("app-list-tile", { title: definition.state === "recommended" ? "推荐 / 最新" : "推荐内容", subtitle: "公开内容会明确标记推荐来源", leading: "discovery" }));
  }
  root.append(content, tabBar("discovery"));
  return root;
}

function momentCard(definition, imageCount = 3) {
  const card = element("section", "c-moment-card");
  card.append(component("app-moment-tile", { ...fixtures.moment, state: definition.state }));
  if (imageCount > 0) card.append(component("app-moment-grid", { count: imageCount, failed: definition.state === "upload-failed" }));
  if (["liked", "comment", "default", "published"].includes(definition.state)) card.append(component("app-moment-reactions", { likes: "林晓、陈默", comments: "林晓：下次一起走！" }));
  return card;
}

function timeline(definition) {
  const root = pageRoot(definition);
  root.append(navigation("畅聊朋友圈", { leading: "返回", action: "发布" }));
  const content = element("div", "p-moments-timeline__content");
  if (definition.state === "empty") content.append(component("app-empty-state", { title: "还没有朋友圈内容", message: "好友发布的内容会出现在这里" }));
  else if (definition.state.includes("failed")) content.append(component("app-empty-state", { kind: "network", title: "加载失败", message: definition.title, action: "重试" }));
  else {
    const cover = element("section", "c-moments-cover");
    cover.append(element("div", "c-moments-cover__art", "畅聊朋友圈"), component("app-avatar", { name: fixtures.currentUser.name, size: "detail" }), element("h2", "c-moments-cover__name", fixtures.currentUser.name));
    content.append(cover, momentCard(definition, 3), momentCard({ ...definition, state: "published" }, 1));
    if (definition.state === "loading") content.append(component("app-status-chip", { status: "processing", label: "正在刷新朋友圈" }));
  }
  root.append(content);
  return root;
}

function media(definition) {
  const counts = { text: 0, single: 1, two: 2, four: 4, nine: 9 };
  const root = pageRoot(definition);
  root.append(navigation("动态媒体", { leading: "返回" }), element("div", "p-moments-media__content"));
  root.querySelector(".p-moments-media__content").append(momentCard(definition, counts[definition.state] ?? 3));
  return root;
}

function composer(definition) {
  const root = pageRoot(definition);
  root.append(navigation("发布朋友圈", { leading: "取消", action: "发表" }));
  const content = element("div", "p-moments-composer__content");
  const field = element("label", "c-moment-composer-field");
  field.append(element("span", "u-visually-hidden", "这一刻的想法"), element("textarea", "c-moment-composer-field__input"));
  field.querySelector("textarea").placeholder = "这一刻的想法…";
  if (definition.state !== "disabled") field.querySelector("textarea").value = "今天的海风很舒服。";
  content.append(field);
  if (["images", "uploading", "upload-failed"].includes(definition.state)) content.append(component("app-moment-grid", { count: 4, failed: definition.state === "upload-failed" }));
  for (const [title, trailing] of [["所在位置", "海滨步道"], ["提醒谁看", "周然"], ["谁可以看", "好友"]]) content.append(component("app-list-tile", { title, trailing, leading: "info" }));
  if (definition.state === "upload-failed") content.append(component("app-action-button", { kind: "danger", icon: "retry", label: "重试上传", action: "moment:retry" }));
  if (definition.state === "uploading") content.append(component("app-status-chip", { status: "processing", label: "正在上传加密图片" }));
  root.append(content);
  return root;
}

function momentSettings(definition) {
  const root = pageRoot(definition);
  root.append(navigation("朋友圈设置", { leading: "返回" }));
  const content = element("div", "p-moments-settings__content");
  for (const [title, trailing] of [["允许陌生人查看", "关闭"], ["朋友圈时间范围", "最近半年"], ["不让他看", "2 人"], ["屏蔽他的朋友圈", "1 人"], ["关闭个性化推荐", "关闭"]]) content.append(component("app-list-tile", { title, trailing, leading: "info" }));
  root.append(content);
  if (definition.state === "range-sheet") root.append(component("app-action-sheet", { title: "朋友圈时间范围", options: "全部,最近半年,最近一个月,最近三天", selected: "最近半年" }));
  return root;
}

function genericMoment(definition) {
  const root = pageRoot(definition);
  root.append(navigation(definition.page === "search" ? "搜索朋友圈" : definition.page === "notifications" ? "互动通知" : "朋友圈", { leading: "返回" }));
  const content = element("div", "p-moments-generic__content");
  if (definition.page === "search") {
    const search = element("input", "c-search-field__input");
    search.placeholder = "搜索正文、用户、话题或位置";
    search.setAttribute("aria-label", "搜索朋友圈");
    content.append(search);
    if (definition.state === "results") content.append(momentCard(definition, 1));
    else if (["no-result", "permission-filtered"].includes(definition.state)) content.append(component("app-empty-state", { title: "没有可显示的结果", message: definition.state === "permission-filtered" ? "无权限内容已安全过滤" : "换个关键词试试" }));
    else if (definition.state === "filters") content.append(component("app-action-sheet", { title: "筛选", options: "正文,用户,话题,位置,时间", selected: "正文" }));
  } else if (definition.page === "notifications" && definition.state === "empty") content.append(component("app-empty-state", { title: "暂无互动通知", message: "点赞和评论会显示在这里" }));
  else {
    content.append(momentCard(definition, 3));
    if (definition.page === "actions" && definition.state === "menu") {
      const menu = element("div", "c-moment-action-menu");
      const like = button("c-moment-action-menu__button", "点赞", "moment:like");
      like.textContent = "点赞";
      const comment = button("c-moment-action-menu__button", "评论", "moment:comment");
      comment.textContent = "评论";
      menu.append(like, comment);
      content.append(menu);
    }
    if (definition.page === "visibility") content.append(component("app-visibility-icon", { visibility: definition.state }));
    if (definition.page === "governance") content.append(component("app-status-chip", { status: definition.state === "failed" || definition.state === "removed" ? "error" : definition.state === "reviewing" || definition.state === "uploading" ? "processing" : "success", label: definition.title }));
    if (definition.page === "recommendation") content.prepend(element("div", "c-segmented-control", definition.state === "latest" || definition.state === "personalization-off" ? "推荐　最新 ✓" : "推荐 ✓　最新"));
    if (definition.page === "detail") content.append(component("app-moment-reactions", { likes: "林晓、陈默、周然", comments: "陈默：照片很好看！" }));
  }
  root.append(content);
  return root;
}

export function renderScreen(definition) {
  let root;
  if (definition.module === "discovery") root = discovery(definition);
  else if (definition.page === "timeline") root = timeline(definition);
  else if (definition.page === "media") root = media(definition);
  else if (definition.page === "composer") root = composer(definition);
  else if (definition.page === "composer-sheet") {
    root = composer({ ...definition, state: "images" });
    root.append(definition.state === "leave-confirm"
      ? component("app-dialog", { kind: "confirm", title: "放弃发布？", message: "正在上传的图片将保留在本地预览。", cancel: "继续编辑", confirm: "离开" })
      : component("app-action-sheet", { title: definition.title, options: definition.state === "visibility" ? "公开,好友,部分可见,不给谁看,仅自己" : "周然,陈默,周末徒步群" }));
  } else if (definition.page === "settings") root = momentSettings(definition);
  else root = genericMoment(definition);
  return createDeviceScreen(definition, root);
}
