import { StrictElement, element } from "./base.js";

export class AppLabeledInputRow extends StrictElement {
  get value() { return this.querySelector("input")?.value ?? this.attr("value"); }

  render() {
    const root = element("label", "c-labeled-input-row");
    const input = element("input", "c-labeled-input-row__input");
    input.value = this.attr("value");
    input.dataset.filled = String(Boolean(input.value));
    input.placeholder = this.attr("placeholder");
    input.disabled = this.attr("enabled", "true") === "false";
    if (this.attr("maxlength")) input.maxLength = Number(this.attr("maxlength"));
    input.setAttribute("aria-label", this.attr("label"));
    root.dataset.state = input.disabled ? "disabled" : input.value ? "filled" : "empty";
    input.addEventListener("focus", () => { root.dataset.state = "editing"; });
    input.addEventListener("input", () => { input.dataset.filled = String(Boolean(input.value)); });
    input.addEventListener("blur", () => { root.dataset.state = input.value ? "filled" : "empty"; });
    root.append(element("span", "c-labeled-input-row__label", this.attr("label")), input, document.createElement("app-gradient-divider"));
    return root;
  }
}
