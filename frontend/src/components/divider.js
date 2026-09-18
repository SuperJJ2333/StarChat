import { StrictElement, element } from "./base.js";

/** 共享渐隐分割线：与 Flutter `WeChatGradientDivider` 同几何与不透明度。 */
export class AppDivider extends StrictElement {
  render() {
    return element("span", "c-gradient-divider");
  }
}
