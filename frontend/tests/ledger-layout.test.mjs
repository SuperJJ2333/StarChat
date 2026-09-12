import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("ledger demo has month groups, type icons, compact filters, and no aggregate", async () => {
  const source = await readFile(new URL("../src/screens/finance.js", import.meta.url), "utf8");
  assert.match(source, /c-ledger-filter__search/u);
  assert.match(source, /c-ledger-month/u);
  assert.match(source, /c-ledger-row__icon/u);
  assert.doesNotMatch(source, /月度合计|本月合计/u);
});
