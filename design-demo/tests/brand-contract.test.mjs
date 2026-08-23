import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const uiDesignUrl = new URL("../../UI_DESIGN.md", import.meta.url);

test("UI_DESIGN uses the approved visible brand", async () => {
  const markdown = await readFile(uiDesignUrl, "utf8");

  assert.doesNotMatch(markdown, /六合通(?:号|朋友圈|点钻红包)?/u);
  assert.match(markdown, /# 畅聊 ChatFlow UI 设计规范/u);
  assert.match(markdown, /畅聊号/u);
  assert.match(markdown, /畅聊朋友圈/u);
  assert.match(markdown, /畅聊点钻红包/u);
});

test("the internal logo asset name remains unchanged", async () => {
  const markdown = await readFile(uiDesignUrl, "utf8");

  assert.match(markdown, /`liuhetong_logo\.svg`/u);
});
