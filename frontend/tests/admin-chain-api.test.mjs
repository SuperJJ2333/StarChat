import test from "node:test";
import assert from "node:assert/strict";
import { createAdminApi } from "../src/admin-api.js";

test("chain queries preserve exact strings, filters and authentication", async () => {
  const calls = [];
  const api = createAdminApi({ token: "test-access", fetchImpl: async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({ items: [{ amount: "10.000001" }] }),
      { headers: { "content-type": "application/json" } });
  } });
  await api.getChainSummary();
  const result = await api.getChainTransactions({ direction: "INFLOW", limit: 25, offset: 25, txid: "a".repeat(64) });
  await api.getChainTransaction("a".repeat(64), 2);
  assert.equal(result.items[0].amount, "10.000001");
  assert.equal(calls[0].url, "/api/v1/admin/wallet/chain/summary");
  const params = new URL(calls[1].url, "https://example.test").searchParams;
  assert.equal(params.get("offset"), "25");
  assert.equal(params.get("direction"), "INFLOW");
  assert.equal(calls[2].url, `/api/v1/admin/wallet/chain/transactions/${"a".repeat(64)}/2`);
  assert.ok(calls.every(call => call.options.headers.Authorization === "Bearer test-access"));
});

test("chain outage remains an error instead of becoming an empty list", async () => {
  const api = createAdminApi({ fetchImpl: async () => new Response(
    JSON.stringify({ error: { code: "TRON_OBSERVER_UNAVAILABLE", message: "暂不可用" } }),
    { status: 503, headers: { "content-type": "application/json" } }) });
  await assert.rejects(api.getChainTransactions(), error => error.status === 503);
});
