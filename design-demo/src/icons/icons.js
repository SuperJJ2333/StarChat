import { element, iconText } from "../components/base.js";

export const iconNames = Object.freeze([
  "add", "back", "call", "camera", "chat", "check", "chevron", "close",
  "contact", "discovery", "document", "error", "gift", "info", "me",
  "microphone", "more", "network", "pause", "play", "retry", "search",
  "send", "wallet", "warning"
]);

export function icon(name, className = "") {
  if (!iconNames.includes(name)) throw new Error(`Unknown icon: ${name}`);
  const value = element("span", className, iconText(name));
  value.setAttribute("aria-hidden", "true");
  return value;
}
