import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { screens } from "../src/catalog/screens.js";
import { componentContracts } from "../src/catalog/contracts.js";

test("replacement is a registered login state with a single acknowledgement", async () => {
  assert.ok(screens.some(screen => screen.id === "auth-login-session-replaced"));
  const auth = await readFile(new URL("../src/screens/auth.js", import.meta.url), "utf8");
  assert.match(auth, /账号已在其他设备登录，当前设备已退出。本地聊天记录已保留。/u);
  assert.match(auth, /知道了/u);
  assert.match(auth, /dialog\.remove\(\)/u);
  assert.ok(componentContracts.find(c => c.tagName === "app-dialog").allowedAttributes.includes("hide-cancel"));
});
