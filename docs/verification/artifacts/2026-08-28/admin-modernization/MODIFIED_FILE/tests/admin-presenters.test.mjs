import test from "node:test";
import assert from "node:assert/strict";
import { presentModuleRows } from "../src/admin-presenters.js";

test("ledger API items render as readable ordered table cells", () => {
  assert.deepEqual(presentModuleRows("ledger", [{
    transaction_id: "tx-1", time: "2026-08-28T12:00:00+00:00", user_id: "u1", type: "ledger.post", amount: "12.34", reason_code: "SUPPORT_GRANT"
  }]), [["tx-1", "2026-08-28T12:00:00+00:00", "u1", "ledger.post", "12.34", "SUPPORT_GRANT"]]);
});

test("wallet API items retain masked address instead of stringifying an object", () => {
  assert.deepEqual(presentModuleRows("wallet", [{
    id: "wd-1", user_id: "u1", amount: "1.250000", address: "T***XXXX", status: "REQUESTED"
  }]), [["wd-1", "u1", "1.250000", "T***XXXX", "REQUESTED"]]);
});
