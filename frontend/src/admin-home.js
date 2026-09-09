import {adminSession} from "./admin-session.js?v=20260908-modern";
import {createAdminShell} from "./admin-dashboard.js?v=20260908-modern";
import {loginView, sessionExpiredDialog, stepUpDialog} from "./admin-login.js?v=20260908-modern";
import { element, button } from "./components/base.js";
import { browserAdminApi, can } from "./admin-api.js?v=20260908-incident-simple";
import { presentModuleRows } from "./admin-presenters.js";
import { chainPanel } from "./admin-chain-panel.js?v=20260908-modern";
import { manualWalletPanel } from "./admin-manual-wallet-panel.js?v=20260909-recovery-copy";

const modules = [
  ["发点钻给客服", "批次与审计记录", "finance", "admin.adjustments.read"],
  ["封禁 IP 和用户", "封禁与解封操作", "security", "admin.bans.read"],
  ["升级为客服", "角色和权限范围", "support-role", "admin.support_roles.read"],
  ["平台注册用户统计", "趋势与渠道分析", "analytics", "admin.analytics.read"],
  ["在线客户数量", "实时在线列表", "online", "admin.presence.read"],
  ["朋友圈原生广告", "素材与投放统计", "ads", "admin.ads.read"],
  ["官方通知公告", "定时发布与阅读", "notice", "admin.notices.read"],
  ["点钻流水", "可追溯复式账本", "ledger", "admin.ledger.read"],
  ["USDT 提现和支付地址", "TRC20 审核与对账", "wallet", "admin.withdrawals.read"]
];
const headerFallbacks = {
  finance: ["批次号", "接收客服", "数量（点钻）", "状态", "发放人/时间"], security: ["对象", "脱敏值", "原因", "时长", "状态"],
  "support-role": ["编号", "姓名", "角色", "权限范围", "状态"], analytics: ["日期", "新增", "主渠道", "验证率", "状态"], online: ["客服编号", "姓名", "状态", "最近活跃", "工单"],
  ads: ["广告 ID", "广告位", "标题", "投放时间", "状态"], notice: ["公告", "受众", "发布时间", "阅读率", "状态"], ledger: ["交易 ID", "时间", "用户", "类型", "金额", "余额变动"], wallet: ["提现单号", "用户", "金额", "支付地址", "状态"]
};

function text(value, fallback = "—") {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value === "object") {
    if ("value" in value) return text(value.value, fallback);
    if ("amount" in value) return text(value.amount, fallback);
    if ("count" in value) return text(value.count, fallback);
    return Object.entries(value).map(([key, item]) => `${key}: ${text(item)}`).join(" · ");
  }
  return String(value);
}
function formatValue(value) { return typeof value === "number" ? new Intl.NumberFormat("zh-CN").format(value) : text(value); }
function emptyState(message) { return element("p", "admin-audit-note", message); }
function tableFor(key, dataset = {}) {
  const headers = dataset.headers ?? headerFallbacks[key]; const rows = Array.isArray(dataset.rows) ? dataset.rows : [];
  const table = element("table", "admin-table"); table.createTHead().insertRow().replaceChildren(...headers.map((h) => element("th", null, h)));
  const body = table.createTBody();
  if (!rows.length) { const tr = body.insertRow(); const td = element("td", "admin-status-cell", "暂无可展示记录"); td.colSpan = headers.length; tr.append(td); }
  rows.forEach((row) => {
    const tr = body.insertRow();
    const cells = Array.isArray(row) ? row : headers.map((h) => row[h]);
    cells.forEach((cell, index) => {
      tr.append(element("td", index === cells.length - 1 ? "admin-status-cell" : null, text(cell)));
    });
  });
  return table;
}
function modulePanel(key, title, context) {
  const panel = element("section", "admin-card admin-module-panel"); const head = element("div", "admin-panel-heading"); const titleBlock = element("div"); titleBlock.append(element("h2", null, title)); head.append(titleBlock, element("span", "admin-chip", "服务端权限已验证")); panel.append(head);
  const dataset = context.modules[key] ?? {};
  const tableDataset = Array.isArray(dataset.items)
    ? { headers: headerFallbacks[key], rows: presentModuleRows(key, dataset.items) }
    : dataset;
  panel.append(tableFor(key, tableDataset));
  if (key === "wallet") {
    const wallet=manualWalletPanel(browserAdminApi(), {actor:context.actor,onReauthenticate:reauthenticateManualWallet,unifiedRefresh:true}),chain=chainPanel(browserAdminApi());
    panel.append(wallet,chain);panel.dispose=()=>{wallet.dispose?.();chain.dispose?.();};
    panel.refresh=async()=>{const results=await Promise.allSettled([wallet.refresh(),chain.refresh(),browserAdminApi().getModule(key).then(payload=>{panel.querySelector('.admin-table').replaceWith(tableFor(key,{headers:headerFallbacks[key],rows:presentModuleRows(key,payload.items??[])}));})]);return results.every(r=>r.status==='fulfilled'&&r.value!==false);};
  }
  if (["security", "support-role", "ads", "notice", "finance"].includes(key)) panel.append(commandForm(key, context));
  panel.append(element("p", "admin-audit-note", "管理员可直接操作；服务端持续保留 RBAC、幂等键、审计与 Outbox。")); return panel;
}
function commandForm(key, context) {
  const form = element("form", "admin-command-form"); const title = element("h3", null, {security:"封禁用户或 IP", "support-role":"配置客服角色", ads:"创建广告草稿", notice:"发布官方公告", finance:"发放点钻给客服"}[key]);
  const fields = {security:[["target_type","封禁类型：user / ip"],["target","用户 ID 或 IP"],["reason_code","原因代码"],["duration_minutes","时长（分钟，可空）"]], "support-role":[["user_id","用户 ID"],["role_code","角色：SUPPORT_AGENT"]], ads:[["advertiser_name","广告主"],["text","广告文案"],["link_url","落地页 URL"]], notice:[["title","公告标题"],["content","公告正文"],["audience","受众：ALL"]], finance:[["user_id","客服用户 ID"],["amount","发放数量（点钻）"],["reason_code","原因代码：SUPPORT_CAIBI_GRANT"]]}[key];
  const hint=element("p","admin-audit-note",key==="support-role"?"填写目标用户 ID，角色选 SUPPORT_AGENT；提交后用户即可获得客服权限。":key==="finance"?"先在“升级为客服”中为目标账号配置 SUPPORT_AGENT，再填写客服用户 ID、点钻数量和原因代码直接发放。":"管理员权限可直接执行此操作，系统会记录幂等键与审计事件。");
  const inputs={}; const fieldsWrap=element("div","admin-command-fields"); fields.forEach(([name, placeholder])=>{const input=element(name==="content"?"textarea":"input","admin-filter");input.name=name;input.placeholder=placeholder;input.required=name!=="duration_minutes";inputs[name]=input;fieldsWrap.append(input);});
  const submit=button("admin-primary","提交操作");submit.type="submit";submit.textContent="提交操作";const status=element("p","admin-audit-note");
  form.append(title,hint,fieldsWrap,submit,status); form.addEventListener("submit",async event=>{event.preventDefault();submit.disabled=true;status.textContent="正在提交…";const body=Object.fromEntries(Object.entries(inputs).map(([name,input])=>[name,input.value]));if(key==="security"&&body.duration_minutes)body.duration_minutes=Number(body.duration_minutes);let path={security:"/api/v1/admin/security/bans","support-role":`/api/v1/admin/support-roles/${encodeURIComponent(body.user_id)}`,ads:"/api/v1/admin/ads",notice:"/api/v1/admin/notices",finance:"/api/v1/admin/finance/adjustments"}[key];if(key==="support-role")delete body.user_id;try{const result=await browserAdminApi().command(path,body,{idempotencyKey:crypto.randomUUID()});status.textContent=key==="finance"?`已发放：${text(result.amount)} 点钻`:`已提交：${text(result.status||result.id,"成功")}`;form.reset();}catch(error){status.textContent=error.message||"提交失败";if(error.code==='RECENT_LOGIN_REQUIRED'){const verify=button('admin-secondary','验证身份');verify.textContent='验证身份';verify.type='button';verify.addEventListener('click',async()=>{verify.disabled=true;const ok=await reauthenticateManualWallet();status.textContent=ok?'身份已验证，请核对表单后再次提交。':'尚未完成身份验证。';});status.append(verify);}}finally{submit.disabled=false;}});return form;
}
function errorView(error, retry) { const root = element("main", "admin-content"); root.append(element("h1", null, error.code === "UNAUTHORIZED" ? "登录已失效" : error.code === "FORBIDDEN" ? "没有访问权限" : "暂时无法加载管理台"), element("p", null, error.message || "请检查网络连接后重试。")); const action = button("admin-primary", "重新加载"); action.textContent = "重新加载"; action.addEventListener("click", retry); root.append(action); return root; }
function adminView(context) {
  return createAdminShell({context,api:browserAdminApi(),modules,renderModule:modulePanel,onLogout:signOut});
}
// 下载链接使用版本无关的稳定别名：/downloads/latest-<abi>.apk
// （服务器侧以符号链接指向当前版本的 APK），发版不再需要改动本页面。
const abiChoices = [
  ["arm64", "arm64（推荐）"],
  ["arm32", "arm32（旧机型）"],
  ["x86_64", "x86_64（模拟器）"],
];
function androidApkPath(abi) {
  return "/downloads/latest-" + abi + ".apk";
}
function platformButtons() {
  const actions = element("div", "land-download-actions");
  const row = element("div", "land-download-row");
  const android = element("a", "land-btn land-btn-primary", "下载 Android 版");
  android.href = androidApkPath("arm64");
  android.setAttribute("download", "");
  android.setAttribute("aria-label", "下载 Android 安装包");
  const abiSelect = element("select", "land-abi-select");
  abiSelect.setAttribute("aria-label", "选择安装包 CPU 架构");
  abiChoices.forEach(([value, label]) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    abiSelect.append(option);
  });
  const abiHint = element("p", "land-abi-hint", androidApkPath("arm64"));
  abiSelect.addEventListener("change", () => {
    const path = androidApkPath(abiSelect.value);
    android.href = path;
    android.setAttribute("download", "");
    abiHint.textContent = path;
  });
  row.append(android, abiSelect, abiHint);
  actions.append(row);
  const ios = element("a", "land-btn land-btn-primary");
  ios.href = "/download";
  ios.setAttribute("aria-label", "下载 iOS 企业测试版 0.3.69（2073）");
  const iosLabel = element("span", "land-platform-chip", "iOS 版下载");
  iosLabel.append(element("span", "land-platform-status", "0.3.69（2073）· 企业测试版"));
  ios.append(iosLabel);
  actions.append(ios);
  return actions;
}
function heroVisual() {
  const visual = element("div", "land-hero-visual");
  const main = element("div", "land-visual-card land-visual-main", "端到端加密");
  const chip = element("div", "land-visual-card land-visual-chip");
  chip.append(element("strong", null, "7×24"), element("span", null, "官方客服在线"));
  const badge = element("div", "land-visual-card land-visual-badge", "盾");
  visual.append(main, badge, chip);
  return visual;
}
function homeView() {
  const page = element("div", "land-page");
  const nav = element("header", "land-nav");
  const navInner = element("div", "land-shell land-nav-inner");
  const logo = element("a", "land-logo");
  logo.href = "/";
  logo.append(element("span", "land-logo-mark", "畅"), document.createTextNode("畅聊 ChatFlow"));
  const links = element("nav", "land-nav-links");
  [["#features", "功能"], ["#security", "安全"], ["#download", "下载"], ["#notice", "公告"]].forEach(([target, label]) => {
    const link = element("a", null, label);
    link.href = target;
    links.append(link);
  });
  const cta = element("a", "land-btn land-btn-primary", "立即下载");
  cta.href = "#download";
  navInner.append(logo, links, cta);
  nav.append(navInner);
  page.append(nav);

  const hero = element("section", "land-hero");
  const heroGrid = element("div", "land-shell land-hero-grid");
  const copy = element("div");
  copy.append(
    element("span", "land-eyebrow", "CHATFLOW · 端到端加密"),
    element("h1", null, "让沟通回归简洁与信任"),
    element("p", "land-hero-copy", "畅聊 ChatFlow 为个人与客服团队提供加密聊天、朋友圈、点钻钱包与红包能力，安全能力默认开启，无需额外配置。")
  );
  const heroActions = element("div", "land-hero-actions");
  const primary = element("a", "land-btn land-btn-primary", "下载 Android 版");
  primary.href = "#download";
  const secondary = element("a", "land-btn land-btn-ghost", "了解安全架构");
  secondary.href = "#security";
  heroActions.append(primary, secondary);
  copy.append(heroActions, element("p", "land-hero-note", "官方签名安装包 · 全量服务端审计"));
  heroGrid.append(copy, heroVisual());
  hero.append(heroGrid);
  page.append(hero);

  const features = element("section", "land-section land-shell");
  features.id = "features";
  const featureHead = element("div", "land-section-head");
  featureHead.append(element("p", "land-kicker", "核心能力"), element("h2", null, "一个应用，覆盖可信沟通全链路"));
  const grid = element("div", "land-grid");
  [["密", "端到端加密", "消息与附件在设备间加密传输，服务端不可见明文。"], ["客", "官方客服", "平台客服角色经过授权与审计，服务过程全程可回溯。"], ["钻", "点钻钱包", "双小数点钻账本，提现与对账流程透明合规。"], ["包", "聊天红包", "拼手气、普通与专属红包，托管与退款状态可查。"], ["圈", "朋友圈", "私密的社区动态与互动，仅授权好友可见。"], ["醒", "消息提醒", "离线推送与本地提醒协同，重要消息不遗漏。"]].forEach(([icon, title, body]) => {
    const card = element("article", "land-card");
    card.append(element("div", "land-card-icon", icon), element("h3", null, title), element("p", null, body));
    grid.append(card);
  });
  features.append(featureHead, grid);
  page.append(features);

  const bandSection = element("section", "land-section land-shell");
  const band = element("div", "land-band");
  band.id = "security";
  band.append(element("h2", null, "安全不是开关，而是默认值"), element("p", null, "从传输、存储到后台操作，畅聊 ChatFlow 以可验证的方式保护每一次沟通与每一笔点钻。"));
  const bandGrid = element("div", "land-band-grid");
  [["端到端加密", "会话密钥仅存于您的设备"], ["7×24 客服", "官方支持与申诉通道"], ["全链路审计", "资金与后台操作留痕"]].forEach(([title, body]) => {
    const item = element("div", "land-band-card");
    item.append(element("strong", null, title), element("span", null, body));
    bandGrid.append(item);
  });
  band.append(bandGrid);
  bandSection.append(band);
  page.append(bandSection);

  const download = element("section", "land-section land-shell");
  download.id = "download";
  const downloadCard = element("div", "land-download-card");
  const downloadCopy = element("div");
  const downloadHead = element("div", "land-section-head");
  downloadHead.append(element("p", "land-kicker", "立即开始"), element("h2", null, "下载畅聊 ChatFlow"));
  downloadCopy.append(downloadHead, element("p", "land-download-note", "Android 安装包由官方渠道分发；iOS 企业测试版 0.3.69（2073）请前往安装页，使用 Safari 安装或扫码下载。"));
  downloadCard.append(downloadCopy, platformButtons());
  download.append(downloadCard);
  page.append(download);

  const notice = element("section", "land-section land-shell");
  notice.id = "notice";
  const noticeHead = element("div", "land-section-head");
  noticeHead.append(element("p", "land-kicker", "官方公告"), element("h2", null, "平台动态"));
  const noticeCard = element("div", "land-notice");
  noticeCard.append(element("strong", null, "新版客户端已发布：转账、深色模式与红包体验全面升级"), element("time", null, "2026-08-29"));
  notice.append(noticeHead, noticeCard);
  page.append(notice);

  const footer = element("footer", "land-footer land-shell");
  const footerNav = element("nav");
  ["帮助中心", "服务条款", "隐私政策"].forEach((label) => footerNav.append(element("a", null, label)));
  footer.append(element("span", null, "© 2026 畅聊 ChatFlow"), footerNav);
  page.append(footer);
  return page;
}

async function signOut(){
  let message='';try{await adminSession.logout();}catch(error){message=error.status===401?'当前标签页的会话已经变化，请重新登录。':'退出请求未能确认，本页已清除登录状态。';}
  finally{disposeCurrent();app.replaceChildren(showLogin());document.body.dataset.appReady='login-required';if(message)app.prepend(element('p','admin-load-error',message));}
}
function showLogin() { return loginView(browserAdminApi(), () => render()); }
let stepUpPending=null;
function reauthenticateManualWallet() {
  return stepUpPending??(stepUpPending=stepUpDialog(adminSession).finally(()=>{stepUpPending=null;}));
}
function disposeCurrent(){app.querySelector('.admin-modern')?.dispose?.();app.querySelector('.admin-manual-wallet-panel')?.dispose?.();}
function expireSession(){
  adminSession.clear();disposeCurrent();app.replaceChildren();
  sessionExpiredDialog(()=>void render());
}
globalThis.addEventListener('admin-session-expired',expireSession);
const app = document.querySelector("#app");
document.documentElement.dataset.theme = document.documentElement.dataset.theme || "light";
const queryMode = new URLSearchParams(location.search).get("view");
const mode = queryMode || (/^(www\.)?liuhetong888\.com$/.test(location.hostname) ? "home" : null);
let renderGeneration=0;
async function render() {
  const generation=++renderGeneration;
  disposeCurrent();document.body.className=mode==='home'?'home-page':'admin-page';
  if(mode==='home'){app.replaceChildren(homeView());document.body.dataset.appReady='true';return;}
  // Remove legacy persistent credentials after upgrading to Cookie-based sessions.
  sessionStorage.removeItem('chatflow_access_token');
  app.replaceChildren(element('main','admin-content','正在加载管理台…'));
  try{await adminSession.getToken();const context=await browserAdminApi().getContext();if(generation!==renderGeneration)return;app.replaceChildren(adminView(context));document.body.dataset.appReady='true';}
  catch(error){if(generation!==renderGeneration)return;if(error.status===401){adminSession.clear();app.replaceChildren(showLogin());document.body.dataset.appReady='login-required';}else{app.replaceChildren(errorView(error,render));document.body.dataset.appReady='error';}}
}
async function checkSession(){if(mode==='home'||!adminSession.peek()||document.hidden)return;try{await adminSession.check();}catch(error){if(error.status===401){disposeCurrent();app.replaceChildren();sessionExpiredDialog(()=>void render());}}}
setInterval(checkSession,30000);document.addEventListener('visibilitychange',checkSession);void render();
