import {pageSizeControl,changePageSize} from './admin-pagination.js?v=20260930-admin-navigation';
import {adminSession} from "./admin-session.js?v=20260929-wallet-workspace";
import {createAdminShell} from "./admin-dashboard.js?v=20260930-admin-navigation";
import {loginView, sessionExpiredDialog, stepUpDialog} from "./admin-login.js?v=20260928-admin-entry";
import { element, button } from "./components/base.js";
import { browserAdminApi, can } from "./admin-api.js?v=20260930-admin-navigation";
import { presentModuleRows } from "./admin-presenters.js";
import { userPanel } from "./admin-user-panel.js?v=20260930-admin-navigation";
import {userDirectory} from './admin-user-directory.js?v=20260930-admin-navigation';
import { ledgerPanel } from './admin-ledger-panel.js?v=20260930-admin-navigation';
import { statusLabel } from "./admin-formatters.js";
import { chainPanel } from "./admin-chain-panel.js?v=20260930-admin-navigation";
import { manualWalletPanel } from "./admin-manual-wallet-panel.js?v=20260930-admin-navigation";
import { walletAccessPanel } from './admin-wallet-access.js?v=20260930-payout-auth-race';
import { supportPanel } from './admin-support-panel.js?v=20260930-admin-navigation';
import { rechargePanel } from './admin-recharge-panel.js?v=20260930-admin-navigation';
import {supportOrderAccessPanel} from './admin-support-order-access.js';
import {supportPayoutPanel} from './admin-support-payout-panel.js?v=20260930-admin-navigation';
import {staffPasswordDialog} from './admin-staff-password-dialog.js';
import {adminLoadingView} from './admin-loading.js';

const modules = [
  ["用户管理", "全部用户资料与点钻余额", "users", "*"],
  ["客服点钻派发", "批次与审计记录", "finance", "admin.adjustments.read"],
  ["封禁 IP 和用户", "封禁与解封操作", "security", "admin.bans.read"],
  ["客服管理", "角色和权限范围", "support-role", "admin.support_roles.read"],
  ["充值与提现请求", "客服订单处理", "recharge", "admin.finance.read"],
  ["平台注册用户统计", "用户查询与注册明细", "analytics", "admin.analytics.read"],
  ["在线客户数量", "实时在线列表", "online", "admin.presence.read"],
  ["朋友圈原生广告", "素材与投放统计", "ads", "admin.ads.read"],
  ["官方通知公告", "定时发布与阅读", "notice", "admin.notices.read"],
  ["点钻流水", "可追溯复式账本", "ledger", "admin.ledger.read"],
  ["USDT提现与支付", "TRC20 审核与对账", "wallet", "admin.withdrawals.read"]
];
const headerFallbacks = {
  finance: ["批次号", "用户标识", "数量（点钻）", "状态", "原因", "创建时间"], security: ["注册时间", "畅聊号", "用户名", "邮箱验证", "账号状态"],
  "support-role": ["畅聊号", "角色", "授权时间"], analytics: ["注册时间", "畅聊号", "用户名", "邮箱验证", "账号状态"], online: ["畅聊号", "状态", "最近活跃"],
  ads: ["广告 ID", "广告主", "文案", "创建时间", "状态"], notice: ["公告", "受众", "发布时间", "状态"], ledger: ["交易 ID", "时间", "用户标识", "类型", "金额", "原因"], wallet: ["托管提现申请编号", "用户标识", "金额", "支付地址", "状态"]
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
  if(key==='users')return userDirectory(browserAdminApi());
  if(key==='support-role')return supportPanel(browserAdminApi(),{mode:'manage'});
  if(key==='recharge')return supportOrderAccessPanel(browserAdminApi(),{actor:context.actor,onExit:context.onWalletExit,onLogin:expireSession,onReauthenticate:reauthenticateManualWallet,renderContent:api=>supportOrderContent(api,context)});
  if(key==='finance')return supportPanel(browserAdminApi(),{mode:'grant'});
  if(key==='ledger')return ledgerPanel(browserAdminApi());
  if(key==='wallet'||key.startsWith('wallet-')) return walletAccessPanel(browserAdminApi(),{
    actor:context.actor,onExit:context.onWalletExit,onLogin:expireSession,onWalletReadDenied:context.onWalletReadDenied,
    expectedCacheEpoch:context.walletCacheEpochAtRender,getCacheEpoch:()=>adminSession.cacheEpoch(),
    renderSetup:(api,onSecurityChanged)=>manualWalletPanel(api,{actor:context.actor,securityOnly:true,onSecurityChanged,onReauthenticate:reauthenticateManualWallet}),
    renderContent:(api,accessController)=>{
      const sameSession=context.walletReadViewEpoch===adminSession.cacheEpoch();
      if(context.walletReadView&&!sameSession)context.onWalletReadDenied?.();
      return walletContent(api,{...context,walletRoute:key,walletReadView:sameSession?context.walletReadView:undefined},accessController);
    }
  });
  if (key === 'security' || key === 'analytics') return userPanel(browserAdminApi(), {module:key,context,initialData:context.modules[key],onReauthenticate:reauthenticateManualWallet});
  const panel = element("section", "admin-card admin-module-panel"); const head = element("div", "admin-panel-heading"); const titleBlock = element("div"); titleBlock.append(element("h2", null, title)); head.append(titleBlock, element("span", "admin-chip", "服务端权限已验证")); panel.append(head);
  const dataset = context.modules[key] ?? {};
  const tableDataset = Array.isArray(dataset.items)
    ? { headers: headerFallbacks[key], rows: presentModuleRows(key, dataset.items) }
    : dataset;
  const rows=element('div','admin-table-scroll'),paging=element('div','admin-user-pagination'),feedback=element('p','admin-audit-note');rows.append(tableFor(key,tableDataset));
  let offset=0,pageSize=10,revision=0,disposed=false,hasMore=dataset.has_more??false;
  const previous=element('button','admin-secondary','上一页'),next=element('button','admin-secondary','下一页');previous.type=next.type='button';
  const controls=()=>{previous.disabled=offset===0;next.disabled=!hasMore;};controls();
  const load=async(targetOffset=offset)=>{const version=++revision;previous.disabled=next.disabled=true;try{const result=await browserAdminApi().getModule(key,{limit:pageSize,offset:targetOffset});if(disposed||version!==revision)return false;offset=targetOffset;hasMore=result.has_more;rows.replaceChildren(tableFor(key,{headers:headerFallbacks[key],rows:presentModuleRows(key,result.items??[])}));feedback.textContent=`第 ${Math.floor(offset/pageSize)+1} 页`;controls();return true;}catch(error){if(!disposed&&version===revision){feedback.textContent=`列表加载失败：${error.message??'请重试'}。上次数据可能已过期。`;controls();}return false;}};
  previous.addEventListener('click',()=>{if(!previous.disabled)void load(Math.max(0,offset-pageSize));});next.addEventListener('click',()=>{if(!next.disabled)void load(offset+pageSize);});
  paging.append(previous,feedback,next,pageSizeControl(changePageSize(value=>pageSize=value,()=>load(0))));panel.append(rows,paging);panel.refresh=()=>load();panel.dispose=()=>{disposed=true;++revision;};
  if (["support-role", "ads", "notice", "finance"].includes(key)) panel.append(commandForm(key, context));
  panel.append(element("p", "admin-audit-note", "按当前账号权限操作，所有提交均保留审计记录。")); return panel;
}
function supportOrderContent(api,context){
  const container=element('section');let child;
  const showRecharge=()=>{child?.dispose?.();child=rechargePanel(api,{actor:context.actor,canReview:can(context,'admin.finance.review'),canApprove:can(context,'*'),canManage:can(context,'*'),onOpenPayout:can(context,'*')?showPayout:null});container.replaceChildren(child);};
  const showPayout=()=>{if(!can(context,'*'))return;child?.dispose?.();child=walletAccessPanel(browserAdminApi(),{actor:context.actor,expectedCacheEpoch:adminSession.cacheEpoch(),getCacheEpoch:()=>adminSession.cacheEpoch(),title:'提现订单',onExit:showRecharge,onLogin:expireSession,onReauthenticate:reauthenticateManualWallet,renderContent:guarded=>supportPayoutPanel(guarded,{actor:context.actor,canOperate:true,onBack:showRecharge,onOpenWallet:context.onOpenPayout})});container.replaceChildren(child);};
  container.refresh=()=>child?.refresh?.();container.refreshOrders=()=>child?.refreshOrders?.();container.dispose=()=>child?.dispose?.();
  showRecharge();return container;
}
function walletContent(api,context,accessController){
  const route=context.walletRoute==='wallet'?'wallet-chain':context.walletRoute;
  const titles={'wallet-chain':'链上流水','wallet-payout':'人工出款','wallet-monitor':'监控与事故','wallet-owner':'所有者转出','wallet-security':'账户安全'};
  const panel=element('section','admin-wallet-workspace');
  const hero=element('header','admin-wallet-hero'),copy=element('div');
  copy.append(element('p','admin-wallet-eyebrow','TRON · OFFICIAL WALLET'),element('h2',null,titles[route]??'链上流水'),element('p',null,'链上观察余额不等于账本可用余额。操作与核验记录分别保留。'));
  hero.append(copy,element('span','admin-wallet-hero-badge','USDT提现与支付'));panel.append(hero);
  const child=route==='wallet-chain'?chainPanel(api,{actorId:context.actor?.id,accessController,initialReadView:context.walletReadView,onSelectOwnerTransfer:context.onSelectOwnerTransfer}):manualWalletPanel(api,{actor:context.actor,onReauthenticate:reauthenticateManualWallet,unifiedRefresh:true,walletAccess:accessController.usesGrant(),accessController,view:route.slice(7),ownerCandidate:context.ownerCandidate});
  child.id=route;panel.append(child);
  panel.exportReadView=()=>child.exportReadView?.()??null;
  panel.suspendForAccessCheck=()=>child.suspendForAccessCheck?.();panel.resumeReadDetail=()=>child.resumeReadDetail?.();
  panel.dispose=()=>child.dispose?.();panel.refresh=()=>child.refresh?.();return panel;
}

function commandForm(key, context) {
  const form = element("form", "admin-command-form"); const title = element("h3", null, {"support-role":"配置客服角色", ads:"创建广告草稿", notice:"发布官方公告", finance:"发放点钻给客服"}[key]);
  const fields = {"support-role":[["user_id","用户 ID"],["role_code","角色：SUPPORT_AGENT"]], ads:[["advertiser_name","广告主"],["text","广告文案"],["link_url","落地页 URL"]], notice:[["title","公告标题"],["content","公告正文"],["audience","受众：ALL"]], finance:[["user_id","客服用户 ID"],["amount","发放数量（点钻）"],["reason_code","原因代码：SUPPORT_CAIBI_GRANT"]]}[key];
  const hint=element("p","admin-audit-note",key==="support-role"?"填写目标用户 ID，角色选 SUPPORT_AGENT；提交后用户即可获得客服权限。":key==="finance"?"先在“升级为客服”中为目标账号配置 SUPPORT_AGENT，再填写客服用户 ID、点钻数量和原因代码直接发放。":"提交后系统将按当前账号权限验证并记录操作。");
  const inputs={}; const fieldsWrap=element("div","admin-command-fields"); fields.forEach(([name, placeholder])=>{const input=element(name==="content"?"textarea":"input","admin-filter");input.name=name;input.placeholder=placeholder;input.required=name!=="duration_minutes";inputs[name]=input;fieldsWrap.append(input);});
  const submit=button("admin-primary","提交操作");submit.type="submit";submit.textContent="提交操作";const status=element("p","admin-audit-note");
  form.append(title,hint,fieldsWrap,submit,status); form.addEventListener("submit",async event=>{event.preventDefault();submit.disabled=true;status.textContent="正在提交…";const body=Object.fromEntries(Object.entries(inputs).map(([name,input])=>[name,input.value]));let path={"support-role":`/api/v1/admin/support-roles/${encodeURIComponent(body.user_id)}`,ads:"/api/v1/admin/ads",notice:"/api/v1/admin/notices",finance:"/api/v1/admin/finance/adjustments"}[key];if(key==="support-role")delete body.user_id;try{const result=await browserAdminApi().command(path,body,{idempotencyKey:crypto.randomUUID()});status.textContent=key==="finance"?`已发放：${text(result.amount)} 点钻`:`已提交：${result.status?statusLabel(result.status):"成功"}`;form.reset();}catch(error){status.textContent=error.message||"提交失败";if(error.code==='RECENT_LOGIN_REQUIRED'){const verify=button('admin-secondary','验证身份');verify.textContent='验证身份';verify.type='button';verify.addEventListener('click',async()=>{verify.disabled=true;const ok=await reauthenticateManualWallet();status.textContent=ok?'身份已验证，请核对表单后再次提交。':'尚未完成身份验证。';});status.append(verify);}}finally{submit.disabled=false;}});return form;
}
function errorView(error, retry) { const root = element("main", "admin-content"); root.append(element("h1", null, error.code === "UNAUTHORIZED" ? "登录已失效" : error.code === "FORBIDDEN" ? "没有访问权限" : "暂时无法加载管理台"), element("p", null, error.message || "请检查网络连接后重试。")); const action = button("admin-primary", "重新加载"); action.textContent = "重新加载"; action.addEventListener("click", retry); root.append(action); return root; }
function adminView(context) {
  return createAdminShell({context,api:browserAdminApi(),modules,renderModule:modulePanel,onLogout:signOut,
    getWalletCacheEpoch:()=>adminSession.cacheEpoch(),
    onChangePassword:()=>staffPasswordDialog({session:adminSession,onSuccess:()=>{
      disposeCurrent();app.replaceChildren(showLogin());document.body.dataset.appReady='login-required';
    }})});
}
// 下载链接使用版本无关的稳定别名：/downloads/latest-<abi>.apk
// （服务器侧以符号链接指向当前版本的 APK），发版不再需要改动本页面。
const abiChoices = [
  ["arm64", "arm64（推荐）"],
  ["arm32", "arm32（旧机型）"],
  ["x86_64", "x86_64（模拟器）"],
];
function androidApkPath(abi) {
  if (abi === "arm64") return "/download?platform=android&install=1";
  return "/downloads/latest-" + abi + ".apk";
}
function platformButtons() {
  const actions = element("div", "land-download-actions");
  const row = element("div", "land-download-row");
  const android = element("a", "land-btn land-btn-primary", "下载 Android 版");
  android.href = androidApkPath("arm64");
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
    if (abiSelect.value === "arm64") android.removeAttribute("download");
    else android.setAttribute("download", "");
    abiHint.textContent = path;
  });
  row.append(android, abiSelect, abiHint);
  actions.append(row);
  const ios = element("a", "land-btn land-btn-primary");
  ios.href = "/download";
  ios.setAttribute("aria-label", "下载 iOS 正式版 0.4.25（2194）");
  const iosLabel = element("span", "land-platform-chip", "iOS 版下载");
  iosLabel.append(element("span", "land-platform-status", "0.4.25（2194）· 企业正式版"));
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
  downloadCopy.append(downloadHead, element("p", "land-download-note", "Android 安装包由官方渠道分发；iOS 正式版 0.4.25（2194）请前往安装页，使用 Safari 安装或扫码下载。"));
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
  ++renderGeneration;
  disposeCurrent();
  const pending=adminLoadingView();pending.querySelector('p').textContent='正在退出管理台';pending.querySelector('small').textContent='本页资料已清除';
  app.replaceChildren(pending);document.body.dataset.appReady='logout-pending';
  let message='';try{await adminSession.logout();}catch(error){message=error.status===401?'当前标签页的会话已经变化，请重新登录。':'退出请求未能确认，本页已清除登录状态。';}
  finally{app.replaceChildren(showLogin());document.body.dataset.appReady='login-required';if(message)app.prepend(element('p','admin-load-error',message));}
}
function showLogin() { return loginView(browserAdminApi(), () => render()); }
let stepUpPending=null;
function reauthenticateManualWallet() {
  return stepUpPending??(stepUpPending=stepUpDialog(adminSession).finally(()=>{stepUpPending=null;}));
}
function disposeCurrent(){app.querySelector('.admin-modern')?.dispose?.();app.querySelector('.admin-manual-wallet-panel')?.dispose?.();}
function expireSession(){
  ++renderGeneration;
  if(adminSession.peek())adminSession.clear();disposeCurrent();app.replaceChildren();
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
  app.replaceChildren(adminLoadingView());
  try{await adminSession.getToken();const context=await browserAdminApi().getContext();if(generation!==renderGeneration)return;app.replaceChildren(adminView(context));document.body.dataset.appReady='true';}
  catch(error){if(generation!==renderGeneration)return;if(error.status===401){adminSession.clear();app.replaceChildren(showLogin());document.body.dataset.appReady='login-required';}else{app.replaceChildren(errorView(error,render));document.body.dataset.appReady='error';}}
}
async function checkSession(){if(mode==='home'||!adminSession.peek()||document.hidden)return;try{await adminSession.check();}catch(error){if(error.status===401)expireSession();}}
setInterval(checkSession,30000);document.addEventListener('visibilitychange',checkSession);void render();
