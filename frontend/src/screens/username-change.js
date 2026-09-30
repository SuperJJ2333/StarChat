import { fixtures } from "../catalog/fixtures.js";
import { element } from "../components/base.js";
import { component, navigation, pageRoot } from "./shared.js";

const key = "chatflow-account-profile-demo";
const rules = "6–20 位，字母开头，仅可使用字母、数字、下划线和短横线。";
export function usernameEditor(definition) {
  const root = pageRoot(definition);
  root.append(navigation("修改畅聊号", { leading: "返回" }));
  const host = element("div", "p-profile-details__content");
  let saved = { username: fixtures.currentUser.username };
  try { saved = { ...saved, ...JSON.parse(globalThis.localStorage?.getItem(key) ?? "{}") }; } catch {}
  let draft = "", message = "", confirmation = false, success = false;
  let next = definition.state === "cooldown" ? Date.now() + 365 * 86400000 : saved.usernameChangedAt ? saved.usernameChangedAt + 365 * 86400000 : 0;
  let failOnce = definition.state === "failed", busy = false;
  function notice(text, error = false) { const node = element("p", error ? "c-form-error" : "c-form-help", text); node.setAttribute("role", error ? "alert" : "status"); return node; }
  function draw() {
    host.replaceChildren(component("app-list-tile", { title: "当前畅聊号", trailing: saved.username, leading: "none" }));
    if (success) host.append(notice(`畅聊号已修改为 ${saved.username}（演示）`));
    else if (next > Date.now()) host.append(notice(`下次可修改日期：${new Date(next).toLocaleDateString("zh-CN")}。每 365 天可修改一次。`));
    else {
      const field = element("label", "c-form-field p-username-input-row");
      const input = element("input", "c-form-field__input");
      input.setAttribute("aria-label", "新畅聊号"); input.maxLength = 20; input.value = draft; input.autocomplete = "off"; input.autocapitalize = "none"; input.spellcheck = false; input.disabled = busy || confirmation;
      const feedback = notice("");
      function validate() {
        draft = input.value.trim();
        message = draft.length < 6 || draft.length > 20 ? "请输入6–20位畅聊号"
          : !/^[A-Za-z]/.test(draft) ? "请以字母开头"
          : !/^[A-Za-z][A-Za-z0-9_-]{5,19}$/.test(draft) ? "仅支持字母、数字、下划线和短横线"
          : ["support008", "reserved_old"].includes(draft.toLowerCase()) ? "该畅聊号已被使用，请换一个" : "";
        feedback.textContent = message || "该畅聊号可以使用（演示）";
        feedback.className = message ? "c-form-error" : "c-form-help";
        feedback.setAttribute("role", message ? "alert" : "status");
        return !message;
      }
      input.addEventListener("input", () => { draft = input.value; feedback.textContent = ""; });
      input.addEventListener("blur", validate);
      field.append(element("span", "c-form-field__label", "新畅聊号"), input);
      const instructions = (title, lines) => {
        const group = element("section", "p-username-rules");
        group.append(element("h2", "p-username-rules__title", title));
        for (const line of lines) group.append(element("p", "p-username-rules__line", line));
        return group;
      };
      host.append(field, instructions("格式规范", ["6–20位，以字母开头", "仅支持字母、数字、下划线和短横线", "大小写视为同一畅聊号"]), instructions("修改规则", ["每365天可修改一次", "修改成功后，请使用新号登录和搜索"]), feedback);
      if (confirmation) host.append(notice(`确认使用 ${draft}？之后请使用新号登录和搜索，聊天记录保持不变。`));
      const save = component("app-action-button", { label: confirmation ? "确认修改畅聊号" : "检查并继续", icon: "check", loading: busy });
      save.addEventListener("click", async () => {
        if (busy) return;
        draft = draft.trim();
        if (!/^[A-Za-z][A-Za-z0-9_-]{5,19}$/.test(draft)) { message = rules; draw(); return; }
        if (["support008", "reserved_old"].includes(draft.toLowerCase())) { message = "此畅聊号已被使用，请更换"; draw(); return; }
        if (!confirmation) { confirmation = true; message = ""; draw(); return; }
        busy = true; draw(); await Promise.resolve(); busy = false;
        if (failOnce) { failOnce = false; message = "保存失败，草稿已保留，请重试"; confirmation = false; }
        else if (draft.toLowerCase() === saved.username.toLowerCase()) { message = "畅聊号未发生变化"; confirmation = false; }
        else { saved = { ...saved, username: draft, usernameChangedAt: Date.now() }; try { globalThis.localStorage?.setItem(key, JSON.stringify(saved)); success = true; } catch { message = "当前浏览器无法保存演示资料，请重试"; } }
        draw();
      });
      host.append(save);
      if (confirmation) { const edit = component("app-action-button", { label: "继续编辑", kind: "secondary", icon: "close" }); edit.addEventListener("click", () => { confirmation = false; draw(); }); host.append(edit); }
    }
    if (message) host.append(notice(message, true));
    host.append(component("app-action-button", { label: "返回个人信息", kind: "secondary", icon: "close", action: "open:profile-details-default" }));
  }
  draw(); root.append(host); return root;
}
