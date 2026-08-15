import { screens, getScreen } from "./catalog/screens.js";
import { button, element } from "./components/base.js";
import { registerComponents } from "./components/register.js";

registerComponents();

const app = document.querySelector("#app");
const params = new URLSearchParams(window.location.search);

function setQuery(updates) {
  const next = new URLSearchParams(window.location.search);
  for (const [key, value] of Object.entries(updates)) {
    if (value) next.set(key, value);
    else next.delete(key);
  }
  window.location.search = next.toString();
}

function selectControl(label, name, values, selected) {
  const wrapper = element("label", "ui-gallery-filter");
  wrapper.append(element("span", "ui-gallery-filter__label", label));
  const select = element("select", "ui-gallery-filter__control");
  select.name = name;
  for (const [value, title] of values) {
    const option = element("option", "ui-gallery-filter__option", title);
    option.value = value;
    option.selected = value === selected;
    select.append(option);
  }
  select.addEventListener("change", () => setQuery({ [name]: select.value }));
  wrapper.append(select);
  return wrapper;
}

function matchesFilters(screen) {
  const module = params.get("module");
  const state = params.get("state");
  const theme = params.get("theme");
  const query = params.get("q")?.trim().toLowerCase();
  if (module && screen.module !== module) return false;
  if (state && screen.state !== state && !screen.tags.includes(state)) return false;
  if (theme && screen.theme !== theme) return false;
  if (query && !`${screen.id} ${screen.title}`.toLowerCase().includes(query)) return false;
  return true;
}

async function renderCard(definition) {
  const card = element("section", "ui-gallery-card");
  card.dataset.screenRef = definition.id;
  const header = element("header", "ui-gallery-card__header");
  const meta = element("div", "ui-gallery-card__meta");
  meta.append(element("h2", "ui-gallery-card__title", definition.title), element("code", "ui-gallery-card__id", definition.id));
  const actions = element("div", "ui-gallery-card__actions");
  const open = button("ui-gallery-card__button", `单独查看 ${definition.title}`, `open:${definition.id}`);
  open.textContent = "单独查看";
  const copy = button("ui-gallery-card__button", `复制 ${definition.id}`, `copy:${definition.id}`);
  copy.textContent = "复制 ID";
  actions.append(open, copy);
  header.append(meta, actions);
  card.append(header);
  try {
    card.append(await definition.component());
  } catch (error) {
    const failure = element("div", "ui-render-error", `渲染失败：${definition.id}`);
    failure.dataset.renderError = error.message;
    card.append(failure);
  }
  return card;
}

function galleryHeader(visibleCount) {
  const header = element("header", "ui-gallery__header");
  const heading = element("div", "ui-gallery__heading");
  heading.append(element("p", "ui-gallery__eyebrow", "HTML → FIGMA REVIEW SYSTEM"), element("h1", "ui-gallery__title", "畅聊 APP 完整设计审查"), element("p", "ui-gallery__summary", `${visibleCount} 个当前画板 · ${screens.length} 个总画板 · iPhone 15 / 393×852`));
  const themeButton = button("ui-gallery__theme", "切换审查主题", "gallery-theme");
  themeButton.textContent = params.get("theme") === "dark" ? "查看浅色" : "查看深色";
  header.append(heading, themeButton);
  return header;
}

function galleryToolbar() {
  const toolbar = element("section", "ui-gallery__toolbar");
  toolbar.setAttribute("aria-label", "画板筛选");
  const search = element("label", "ui-gallery-filter ui-gallery-filter--search");
  search.append(element("span", "ui-gallery-filter__label", "搜索"));
  const input = element("input", "ui-gallery-filter__control");
  input.type = "search";
  input.name = "q";
  input.placeholder = "页面名或 Screen ID";
  input.value = params.get("q") ?? "";
  input.addEventListener("change", () => setQuery({ q: input.value.trim() }));
  search.append(input);
  const modules = [...new Set(screens.map((screen) => screen.module))].sort().map((module) => [module, module]);
  toolbar.append(
    search,
    selectControl("模块", "module", [["", "全部模块"], ...modules], params.get("module") ?? ""),
    selectControl("状态", "state", [["", "全部状态"], ["error", "异常"], ["loading", "加载"], ["empty", "空状态"], ["overlay", "弹层"], ["network", "网络"]], params.get("state") ?? ""),
    selectControl("主题", "theme", [["", "全部主题"], ["light", "浅色"], ["dark", "深色"]], params.get("theme") ?? "")
  );
  return toolbar;
}

async function renderGallery() {
  document.documentElement.dataset.theme = params.get("theme") === "dark" ? "dark" : "light";
  document.body.className = "ui-gallery-page";
  const visible = screens.filter(matchesFilters);
  const gallery = element("main", "ui-gallery");
  gallery.append(galleryHeader(visible.length), galleryToolbar());
  const grid = element("div", "ui-gallery__grid");
  const cards = await Promise.all(visible.map(renderCard));
  grid.append(...cards);
  gallery.append(grid);
  app.replaceChildren(gallery);
  document.body.dataset.visibleCount = String(visible.length);
}

async function renderSingle(id) {
  const definition = getScreen(id);
  const captureMode = params.get("capture") === "1";
  document.documentElement.dataset.theme = definition.theme;
  document.body.className = captureMode ? "ui-capture-page" : "ui-single-page";
  const screen = await definition.component();
  if (captureMode) {
    app.replaceChildren(screen);
    document.body.dataset.visibleCount = "1";
    return;
  }
  const wrapper = element("main", "ui-single");
  const back = button("ui-single__back", "返回设计审查画廊", "gallery-back");
  back.textContent = "← 返回全部画板";
  wrapper.append(back, screen);
  app.replaceChildren(wrapper);
  document.body.dataset.visibleCount = "1";
}

const routeMap = Object.freeze({
  "tab:messages": "messages-inbox-default",
  "tab:contacts": "contacts-index-default",
  "tab:discovery": "discovery-home-default",
  "tab:profile": "profile-home-default",
  "auth:login": "messages-inbox-default",
  "auth:registration": "auth-registration-default",
  "auth:verification": "auth-verification-code",
  "auth:complete": "messages-inbox-default",
  "friend:message": "chat-room-mixed"
});

document.addEventListener("click", async (event) => {
  const target = event.target.closest("[data-action]");
  if (!target) return;
  const action = target.dataset.action;
  if (action.startsWith("open:")) setQuery({ screen: action.slice(5), module: "", state: "", theme: "", q: "" });
  else if (action.startsWith("copy:")) await navigator.clipboard?.writeText(action.slice(5));
  else if (action === "gallery-back") window.location.search = "";
  else if (action === "gallery-theme") setQuery({ theme: params.get("theme") === "dark" ? "light" : "dark" });
  else if (routeMap[action]) setQuery({ screen: routeMap[action], module: "", state: "", theme: "", q: "" });
});

try {
  const screenId = params.get("screen");
  if (screenId) await renderSingle(screenId);
  else await renderGallery();
  document.body.dataset.appReady = "true";
} catch (error) {
  const failure = element("main", "ui-render-error", "畅聊设计 Demo 无法渲染");
  failure.dataset.renderError = error.message;
  app.replaceChildren(failure);
  document.body.dataset.appReady = "false";
}
