import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

const symbols = {copy:"copy",delete:"delete",pin:"upload",unread:"chat",hide:"close",group:"contact",add:"user-add",scan:"search"};
export class AppAnchoredActionMenu extends StrictElement {
  render() {
    const root = element("div", "c-anchored-menu");
    root.setAttribute("role", "menu");
    root.dataset.arrowAtTop = String(this.boolAttr("arrow-at-top"));
    const grid = element("div", "c-anchored-menu__grid");
    const options = JSON.parse(this.attr("options", "[]"));
    for (const option of options) {
      const item = button("c-anchored-menu__item", option.label, option.id);
      item.setAttribute("role", "menuitem");
      item.disabled = option.disabled === true;
      const glyph = icon(symbols[option.icon ?? option.id] ?? "more", "c-anchored-menu__icon");
      glyph.setAttribute("aria-hidden", "true");
      item.append(glyph, element("span", "c-anchored-menu__label", option.label));
      grid.append(item);
    }
    root.append(grid);
    return root;
  }
}
