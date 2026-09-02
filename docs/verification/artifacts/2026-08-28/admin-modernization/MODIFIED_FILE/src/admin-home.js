import { element, button } from "./components/base.js";
import { browserAdminApi, can } from "./admin-api.js";
import { presentModuleRows } from "./admin-presenters.js";

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
const cardDefinitions = [["registered_users", "注册用户", "admin.analytics.read"], ["online_customers", "在线客户", "admin.presence.read"], ["pending_withdrawals", "待审核提现", "admin.withdrawals.read"], ["today_point_volume", "今日点钻流水", "admin.ledger.read"]];
const navigationGroups = {
  "概览": [],
  "用户与安全": ["security", "support-role", "analytics", "online"],
  "运营": ["ads", "notice"],
  "财务": ["finance", "ledger", "wallet"],
  "系统": []
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
  const filters = element("div", "admin-filters"); ["搜索用户 / 交易 ID", "状态：全部", "日期范围"].forEach((label) => { const input = element("input", "admin-filter"); input.setAttribute("aria-label", label); input.placeholder = label; filters.append(input); });
  if (can(context, `admin.${key.replace("support-role", "support_roles")}.export`)) { const exportButton = button("admin-secondary", "导出当前筛选"); exportButton.textContent = "导出"; filters.append(exportButton); }
  const dataset = context.modules[key] ?? {};
  const tableDataset = Array.isArray(dataset.items)
    ? { headers: headerFallbacks[key], rows: presentModuleRows(key, dataset.items) }
    : dataset;
  panel.append(filters, tableFor(key, tableDataset));
  if (["security", "support-role", "ads", "notice", "finance", "wallet"].includes(key)) panel.append(commandForm(key, context));
  panel.append(element("p", "admin-audit-note", "管理员可直接操作；服务端持续保留 RBAC、幂等键、审计与 Outbox。")); return panel;
}
function commandForm(key, context) {
  const form = element("form", "admin-command-form"); const title = element("h3", null, {security:"封禁用户或 IP", "support-role":"配置客服角色", ads:"创建广告草稿", notice:"发布官方公告", finance:"处理点钻申请", wallet:"处理提现申请"}[key]);
  const fields = {security:[["target_type","封禁类型：user / ip"],["target","用户 ID 或 IP"],["reason_code","原因代码"],["duration_minutes","时长（分钟，可空）"]], "support-role":[["user_id","用户 ID"],["role_code","角色：SUPPORT_AGENT"]], ads:[["advertiser_name","广告主"],["text","广告文案"],["link_url","落地页 URL"]], notice:[["title","公告标题"],["content","公告正文"],["audience","受众：ALL"]], finance:[["request_id","点钻申请 ID"]], wallet:[["withdrawal_id","提现单 ID"]]}[key];
  const hint=element("p","admin-audit-note",key==="support-role"?"填写目标用户 ID，角色选 SUPPORT_AGENT；提交后用户即可获得客服权限。":key==="finance"?"管理员可直接处理点钻申请。":key==="wallet"?"管理员可直接处理提现申请。":"管理员权限可直接执行此操作，系统会记录幂等键与审计事件。");
  const inputs={}; const fieldsWrap=element("div","admin-command-fields"); fields.forEach(([name, placeholder])=>{const input=element(name==="content"?"textarea":"input","admin-filter");input.name=name;input.placeholder=placeholder;input.required=name!=="duration_minutes";inputs[name]=input;fieldsWrap.append(input);});
  const submit=button("admin-primary","提交操作");submit.type="submit";submit.textContent="提交操作";const status=element("p","admin-audit-note");
  form.append(title,hint,fieldsWrap,submit,status); form.addEventListener("submit",async event=>{event.preventDefault();submit.disabled=true;status.textContent="正在提交…";const body=Object.fromEntries(Object.entries(inputs).map(([name,input])=>[name,input.value]));if(key==="security"&&body.duration_minutes)body.duration_minutes=Number(body.duration_minutes);let path={security:"/api/v1/admin/security/bans","support-role":`/api/v1/admin/support-roles/${encodeURIComponent(body.user_id)}`,ads:"/api/v1/admin/ads",notice:"/api/v1/admin/notices",finance:`/api/v1/admin/finance/adjustments/${encodeURIComponent(body.request_id)}/review`,wallet:`/api/v1/admin/finance/withdrawals/${encodeURIComponent(body.withdrawal_id)}/review`}[key];if(key==="support-role")delete body.user_id;if(["finance","wallet"].includes(key)){body.approve=true;delete body.request_id;delete body.withdrawal_id;}try{const result=await browserAdminApi().command(path,body,{idempotencyKey:crypto.randomUUID()});status.textContent=`已提交：${text(result.status||result.id,"成功")}`;form.reset();}catch(error){status.textContent=error.message||"提交失败";}finally{submit.disabled=false;}});return form;
}
function errorView(error, retry) { const root = element("main", "admin-content"); root.append(element("h1", null, error.code === "UNAUTHORIZED" ? "登录已失效" : error.code === "FORBIDDEN" ? "没有访问权限" : "暂时无法加载管理台"), element("p", null, error.message || "请检查网络连接后重试。")); const action = button("admin-primary", "重新加载"); action.textContent = "重新加载"; action.addEventListener("click", retry); root.append(action); return root; }
function adminView(context) {
  const page = element("div", "admin-page"), shell = element("div", "admin-shell"), side = element("aside", "admin-sidebar"); side.append(element("div", "admin-logo", "ChatFlow 管理台"));
  const nav = element("nav", "admin-nav"); ["概览", "用户与安全", "运营", "财务", "系统"].forEach((name, index) => { const item = button("", name); item.type = "button"; item.textContent = name; if (!index) item.classList.add("active"); item.addEventListener("click", () => { nav.querySelectorAll("button").forEach((node) => node.classList.remove("active")); item.classList.add("active"); const keys = navigationGroups[name]; const panels = [...moduleList.querySelectorAll(".admin-module")]; panels.forEach((node) => { node.hidden = Boolean(keys.length && !keys.includes(node.dataset.module)); }); content.querySelector(".admin-route-state")?.remove(); const state = element("section", "admin-card admin-route-state"); state.append(element("h2", null, name), element("p", "admin-audit-note", keys.length ? `已显示 ${name} 的可访问模块，选择卡片即可进入。` : "系统设置正在逐项接入服务端能力；当前没有已授权的系统操作。")); content.insertBefore(state, list); state.scrollIntoView({ behavior: "smooth", block: "start" }); }); nav.append(item); }); side.append(nav);
  const main = element("div", "admin-main"), top = element("header", "admin-topbar"), search = element("input", "admin-search"); search.placeholder = "搜索用户、交易或工单"; search.setAttribute("aria-label", "全局搜索"); const actor = context.actor; top.append(search, element("span", "admin-chip", `${text(actor.display_name)} · ${text((actor.roles || []).join(" / "), "管理员")}`));
  const content = element("main", "admin-content"), heading = element("div", "admin-heading"), headingText = element("div"); headingText.append(element("h1", null, "运营概览"), element("p", null, "来自 ChatFlow 业务服务的实时运营数据")); heading.append(headingText); if (can(context, "admin.operations.create")) { const add = button("admin-primary", "新建操作"); add.textContent = "+ 新建操作"; heading.append(add); } content.append(heading);
  const cards = element("div", "admin-kpis"); cardDefinitions.filter(([, , permission]) => can(context, permission)).forEach(([key, label]) => { const metric = context.overview[key] ?? {}; const card = element("article", "admin-card"); card.append(element("div", "admin-kpi-label", label), element("div", "admin-kpi-value", formatValue(metric.value ?? metric)), element("div", "admin-trend", text(metric.change, "实时"))); cards.append(card); }); content.append(cards);
  const grid = element("div", "admin-grid"); if (can(context, "admin.analytics.read")) { const chart = element("section", "admin-card"); chart.append(element("h2", null, "注册用户趋势")); const bars = element("div", "admin-chart"); (context.overview.registration_trend ?? []).forEach((point) => { const bar = element("div", "admin-bar"); bar.dataset.value = String(point.value ?? point); bar.setAttribute("aria-label", `${text(point.date, "统计")}: ${text(point.value ?? point)}`); bars.append(bar); }); chart.append(bars.children.length ? bars : emptyState("暂无趋势数据")); grid.append(chart); } if (can(context, "admin.withdrawals.read")) { const queue = element("section", "admin-card"); const withdrawals = context.modules.wallet?.items ?? []; queue.append(element("h2", null, "待处理提现"), tableFor("wallet", { headers: headerFallbacks.wallet, rows: presentModuleRows("wallet", withdrawals) })); grid.append(queue); } if (grid.children.length) content.append(grid);
  const list = element("section", "admin-card"); list.append(element("h2", null, "功能模块")); const moduleList = element("div", "admin-module-list"); modules.filter(([, , , permission]) => can(context, permission)).forEach(([name, description, key]) => { const item = button("admin-module", name); item.type = "button"; item.dataset.module = key; item.append(element("strong", null, name), element("span", null, description)); item.addEventListener("click", async () => { document.querySelectorAll(".admin-module").forEach((node) => node.classList.remove("is-selected")); item.classList.add("is-selected"); content.querySelector(".admin-module-panel")?.remove(); const loading = element("section", "admin-card admin-module-panel", "正在加载模块数据…"); content.insertBefore(loading, list); try { const payload = await browserAdminApi().getModule(key); const panel = modulePanel(key, name, { ...context, modules: { ...context.modules, [key]: payload } }); loading.replaceWith(panel); panel.scrollIntoView({ behavior: "smooth", block: "start" }); } catch (error) { loading.replaceWith(errorView(error, () => item.click())); } }); moduleList.append(item); }); list.append(moduleList.children.length ? moduleList : emptyState("当前账户没有后台模块权限。")); content.append(list); main.append(top, content); shell.append(side, main); page.append(shell); return page;
}
function homeView() { const page = element("div", "home-page"), nav = element("header", "home-nav"); nav.append(element("div", "home-logo", "ChatFlow · 畅聊")); const links = element("nav", "home-nav-links"); ["产品", "安全", "公告"].forEach((label) => links.append(element("a", null, label))); nav.append(links); page.append(nav); const hero = element("section", "home-hero"), inner = element("div", "home-hero-inner"), copy = element("div"); copy.append(element("span", "home-eyebrow", "CHATFLOW · TRUSTED COMMUNICATION"), element("h1", null, "让每一次连接，都值得信任"), element("p", null, "端到端加密聊天 · 官方客服支持 · 一站式可信沟通平台")); inner.append(copy, element("div", "home-hero-visual", "安全连接")); hero.append(inner); page.append(hero); const section = element("section", "home-section"); section.append(element("h2", null, "核心能力")); const cards = element("div", "home-cards"); ["消息", "客服", "点钻", "红包", "钱包"].forEach((label) => { const card = element("article", "home-feature"); card.append(element("div", "home-feature-icon", label), element("h3", null, label), element("p", null, "安全、透明、可审计的产品能力")); cards.append(card); }); section.append(cards); const announcement = element("div", "home-announcement"); announcement.append(element("h2", null, "官方公告"), element("p", null, "平台服务升级公告")); section.append(announcement); page.append(section, element("footer", "home-footer", "ChatFlow 畅聊　帮助中心　服务条款　隐私政策")); return page; }

function loginView(onSuccess) {
  const page = element("main", "admin-login-page");
  const brand = element("section", "admin-login-brand");
  const mark = element("div", "admin-login-mark", "畅");
  brand.append(mark, element("p", "admin-login-eyebrow", "CHATFLOW ADMIN CONSOLE"), element("h1", null, "畅聊管理后台"), element("p", "admin-login-intro", "统一、可靠地处理用户服务、平台运营与资金审核。"));
  const card = element("section", "admin-card admin-login-card");
  card.append(element("p", "admin-login-kicker", "管理员入口"), element("h2", null, "欢迎回来"), element("p", "admin-audit-note", "请使用已授权的管理员账号登录。"));
  const form = element("form", "admin-login-form");
  const username = element("input", "admin-filter"); username.name = "username"; username.placeholder = "请输入管理员账号"; username.autocomplete = "username"; username.required = true; username.setAttribute("aria-label", "管理员账号");
  const passwordRow = element("div", "admin-password-row");
  const password = element("input", "admin-filter"); password.name = "password"; password.type = "password"; password.placeholder = "请输入密码"; password.autocomplete = "current-password"; password.required = true; password.setAttribute("aria-label", "密码");
  const toggle = button("admin-password-toggle", "显示密码"); toggle.type = "button"; toggle.textContent = "显示"; toggle.addEventListener("click", () => { const visible = password.type === "text"; password.type = visible ? "password" : "text"; toggle.textContent = visible ? "显示" : "隐藏"; toggle.setAttribute("aria-label", visible ? "显示密码" : "隐藏密码"); }); passwordRow.append(password, toggle);
  const submit = button("admin-primary", "登录"); submit.type = "submit"; submit.textContent = "登录"; const status = element("p", "admin-audit-note");
  const captcha = element("input", "admin-filter"); captcha.placeholder = "验证码"; captcha.setAttribute("aria-label", "验证码"); captcha.hidden = true;
  let failures = 0;
  form.append(username, passwordRow, captcha, submit, status); form.addEventListener("submit", async (event) => { event.preventDefault(); submit.disabled = true; status.textContent = "正在验证…"; try { const tokens = await browserAdminApi().login({ username: username.value, password: password.value, device_key: "admin-browser", device_name: "ChatFlow Admin" }); sessionStorage.setItem("chatflow_access_token", tokens.access_token); status.textContent = "登录成功"; onSuccess(); } catch (error) { failures += 1; if (failures >= 3) { captcha.hidden = false; captcha.required = true; } status.textContent = failures >= 3 ? "登录失败 3 次，请输入验证码后重试。" : (error.message || "账号或密码错误，请重试"); submit.disabled = false; } }); card.append(form); page.append(brand, card); return page;
}

const app = document.querySelector("#app");
document.documentElement.dataset.theme = document.documentElement.dataset.theme || "light";
const queryMode = new URLSearchParams(location.search).get("view");
const mode = queryMode || (/^(www\.)?liuhetong888\.com$/.test(location.hostname) ? "home" : null);
async function render() { document.body.className = mode === "home" ? "home-page" : "admin-page"; if (mode === "home") { app.replaceChildren(homeView()); document.body.dataset.appReady = "true"; return; } const token = sessionStorage.getItem("chatflow_access_token"); if (!token) { app.replaceChildren(loginView(render)); document.body.dataset.appReady = "login-required"; return; } app.replaceChildren(element("main", "admin-content", element("h1", null, "正在加载 ChatFlow 管理台…"))); try { app.replaceChildren(adminView(await browserAdminApi().getContext())); document.body.dataset.appReady = "true"; } catch (error) { if (error.status === 401) sessionStorage.removeItem("chatflow_access_token"); app.replaceChildren(errorView(error, render)); document.body.dataset.appReady = "error"; } } render();
