import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("ledger demo keeps the verified detail hero, counterparty row and copy control", async () => {
  const source = await readFile(new URL("../src/screens/finance.js", import.meta.url), "utf8");
  assert.match(source, /c-ledger-detail-hero/u);
  assert.match(source, /交易对方/u);
  assert.match(source, /复制账单ID/u);
  assert.doesNotMatch(source, /月度合计|本月合计/u);
});
