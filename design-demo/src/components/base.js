import { contractFor } from "../catalog/contracts.js";

export function element(tagName, className, text) {
  const value = document.createElement(tagName);
  if (className) value.className = className;
  if (text !== undefined && text !== null) value.textContent = String(text);
  return value;
}

export function button(className, label, action) {
  const value = element("button", className);
  value.type = "button";
  value.setAttribute("aria-label", label);
  if (action) value.dataset.action = action;
  return value;
}

export function iconText(name) {
  const labels = {
    add: "+",
    back: "‹",
    call: "●",
    camera: "▣",
    chat: "●",
    check: "✓",
    chevron: "›",
    close: "×",
    contact: "●",
    discovery: "◇",
    document: "▤",
    error: "!",
    gift: "▣",
    info: "i",
    me: "●",
    microphone: "●",
    more: "•••",
    network: "⌁",
    pause: "Ⅱ",
    play: "▶",
    retry: "↻",
    search: "⌕",
    send: "↑",
    wallet: "▰",
    warning: "!"
  };
  if (!(name in labels)) throw new Error(`Unknown icon: ${name}`);
  return labels[name];
}

export class StrictElement extends HTMLElement {
  connectedCallback() {
    this.renderContract();
  }

  attributeChangedCallback() {
    if (this.isConnected) this.renderContract();
  }

  attr(name, fallback = "") {
    return this.getAttribute(name) ?? fallback;
  }

  boolAttr(name) {
    return this.hasAttribute(name) && this.getAttribute(name) !== "false";
  }

  renderContract() {
    const contract = contractFor(this.localName);
    const illegal = this.getAttributeNames().filter((name) => !contract.allowedAttributes.includes(name));
    if (illegal.length) throw new Error(`${this.localName} rejects attributes: ${illegal.join(", ")}`);
    this.replaceChildren(this.render());
  }
}
