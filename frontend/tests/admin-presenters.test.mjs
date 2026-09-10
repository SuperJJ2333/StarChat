import test from "node:test";
import assert from "node:assert/strict";
import { presentModuleRows } from "../src/admin-presenters.js";

test("ledger API items render as readable ordered table cells", () => {
  assert.deepEqual(presentModuleRows("ledger", [{
    transaction_id: "tx-1", time: "2026-08-28T12:00:00+00:00", user_id: "u1", type: "ledger.post", amount: "12.34", reason_code: "SUPPORT_GRANT"
  }]), [["tx-1", "2026-08-28 20:00:00", "u1", "账本记账", "12.34", "客服点钻发放"]]);
});

test("wallet API items retain masked address instead of stringifying an object", () => {
  assert.deepEqual(presentModuleRows("wallet", [{
    id: "wd-1", user_id: "u1", amount: "1.250000", address: "T***XXXX", status: "REQUESTED"
  }]), [["wd-1", "u1", "1.250000", "T***XXXX", "待审核"]]);
});

test('explicit field mapping ignores insertion order and unknown fields',()=>{
  assert.deepEqual(presentModuleRows('finance',[{extra:'secret',created_at:'2026-09-10T00:00:00Z',reason_code:'SUPPORT_CAIBI_GRANT',amount:'9007199254740993.00',status:'POSTED',user_id:'user',id:'batch'}]),
    [['batch','user','9007199254740993.00','已入账','客服点钻发放','2026-09-10 08:00:00']]);
  assert.deepEqual(presentModuleRows('not-supported',[{unexpected:'secret'}]),[]);
});

test('analytics uses actual username nickname verification timestamp and status',()=>{
  assert.deepEqual(presentModuleRows('analytics',[{id:'uuid-not-a-handle',created_at:'2026-09-10T00:00:00Z',username:'chat123',nickname:'小星',email_verified_at:null,status:'BANNED'}]),
    [['2026-09-10 08:00:00','chat123','小星','未验证','已封禁']]);
});
