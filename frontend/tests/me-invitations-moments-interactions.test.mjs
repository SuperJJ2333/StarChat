import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getScreen } from "../src/catalog/screens.js";

const source = path => readFile(new URL(path, import.meta.url), "utf8");

test("Me child routes, invitation history, and interaction inbox have reviewable states", () => {
  for (const id of [
    "profile-details-nickname-limit",
    "profile-details-signature-limit",
    "profile-invitation-history",
    "profile-invitation-empty",
    "profile-invitation-more",
    "moments-personal-default",
    "moments-personal-empty",
    "moments-interactions-default",
    "moments-interactions-empty",
    "moments-interactions-unavailable",
  ]) assert.equal(getScreen(id).id, id);
});

test("Me demo routes have the correct destinations and distinct interaction wording", async () => {
  const [profile, moments, registry] = await Promise.all([
    source("../src/screens/profile.js"),
    source("../src/screens/moments.js"),
    source("../../packages/ui-contracts/changliao-component-registry.json"),
  ]);
  assert.match(profile, /open:moments-personal-default/u);
  assert.match(profile, /open:profile-invitation-history/u);
  assert.match(profile, /Intl\.Segmenter/u);
  assert.match(profile, /昵称最多支持12个字符/u);
  assert.match(profile, /个性签名最多支持20个字符/u);
  assert.match(moments, /全部互动消息/u);
  assert.match(moments, /评论了你的朋友圈/u);
  assert.match(moments, /回复了你的评论/u);
  assert.match(moments, /该内容不可查看/u);
  assert.ok(JSON.parse(registry).feedbackContracts["2026-09-24-me-invitations-moments-interactions"]);
});
