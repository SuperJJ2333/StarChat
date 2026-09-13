import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { componentContracts } from "../src/catalog/contracts.js";
import { getScreen } from "../src/catalog/screens.js";

test("finance remediation registers approved ledger, shared picker and nudge-limit demos", async () => {
  for (const id of ["caibi-ledger-all", "caibi-transaction-detail", "caibi-group-member-picker-ready", "caibi-group-member-picker-loading", "caibi-group-member-picker-empty", "caibi-group-member-picker-error", "feedback-toast-nudge-rate-limited"]) assert.equal(getScreen(id).id, id);
  assert.ok(componentContracts.some(({ tagName }) => tagName === "app-group-member-picker"));
  const source = await readFile(new URL("../src/screens/finance.js", import.meta.url), "utf8");
  assert.match(source, /remark \|\| row\.nickname \|\| row\.username/u);
  assert.match(source, /账单ID已复制/u);
  const picker = await readFile(new URL("../src/components/finance.js", import.meta.url), "utf8");
  assert.match(picker, /document\.createElement\("app-avatar"\)/u);
  assert.match(picker, /avatarSlot\.append\(avatar\)/u);
  assert.doesNotMatch(picker, /avatar\.className/u);
  assert.doesNotMatch(picker, /Matrix 头像/u);
});
