import { element } from "../components/base.js";
import { createStatusBarNode } from "../components/chrome.js";

export function createDeviceScreen(definition, content) {
  const screen = element("article", "ui-screen");
  screen.classList.add(`ui-screen--h-${definition.height}`);
  screen.dataset.screenId = definition.id;
  screen.dataset.module = definition.module;
  screen.dataset.page = definition.page;
  screen.dataset.state = definition.state;
  screen.dataset.theme = definition.theme;
  screen.setAttribute("aria-label", definition.title);

  const device = element("div", "ui-device");
  const statusBar = createStatusBarNode();
  const viewport = element("main", "ui-device__viewport");
  viewport.append(content);
  const home = element("footer", "c-home-indicator");
  home.setAttribute("aria-hidden", "true");
  device.append(statusBar, viewport, home);
  screen.append(device);
  return screen;
}

export function pageRoot(definition, children = []) {
  const root = element("section", `p-${definition.module}-${definition.page}`);
  root.append(...children);
  return root;
}

export function component(tagName, attributes = {}) {
  const value = document.createElement(tagName);
  for (const [name, attribute] of Object.entries(attributes)) {
    if (attribute !== undefined && attribute !== null && attribute !== false) {
      value.setAttribute(name, attribute === true ? "true" : String(attribute));
    }
  }
  return value;
}

export function navigation(title, options = {}) {
  return component("app-navigation-bar", {
    title,
    leading: options.leading,
    action: options.action
  });
}

export function tabBar(active) {
  return component("app-tab-bar", { active });
}
