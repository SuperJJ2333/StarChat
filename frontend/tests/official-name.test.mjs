import test from "node:test";
import assert from "node:assert/strict";
globalThis.HTMLElement = class {};
const { validOfficialBadge } = await import("../src/components/official-name.js");

test("official suffix accepts only two to six Chinese characters", () => {
  assert.equal(validOfficialBadge("官方客服"), "官方客服");
  assert.equal(validOfficialBadge("财务支持专员"), "财务支持专员");
  assert.equal(validOfficialBadge("客服"), "客服");
  assert.equal(validOfficialBadge("A客服"), "");
  assert.equal(validOfficialBadge("客"), "");
  assert.equal(validOfficialBadge("超长官方客服称号"), "");
});

test("officialName creates a separate badge element only from authority", async () => {
  globalThis.document = { createElement() { return { className: "", textContent: "", children: [], append(...nodes) { this.children.push(...nodes); } }; } };
  const { officialName } = await import("../src/components/official-name.js");
  const verified = officialName("备注用户", "官方客服");
  assert.equal(verified.children.length, 2);
  assert.equal(verified.children[1].className, "c-official-name__badge");
  const fakeName = officialName("普通用户 @官方客服", "");
  assert.equal(fakeName.children.length, 1);
});

test("a name containing a fake suffix is not authority", () => {
  assert.equal(validOfficialBadge(undefined), "");
  assert.equal(validOfficialBadge("普通用户 @官方客服"), "");
});
