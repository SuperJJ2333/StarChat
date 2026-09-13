import { StrictElement, element } from "./base.js";

export function validOfficialBadge(value) {
  return /^[\u4e00-\u9fff]{2,6}$/.test(String(value ?? "")) ? String(value) : "";
}

export function officialName(name, official) {
  const root = element("span", "c-official-name");
  root.append(element("span", "c-official-name__text", name));
  const badge = validOfficialBadge(official);
  if (badge) root.append(element("span", "c-official-name__badge", `@${badge}`));
  return root;
}

export class AppOfficialName extends StrictElement {
  render() { return officialName(this.attr("name", "用户"), this.attr("official")); }
}
