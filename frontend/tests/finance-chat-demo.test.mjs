import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";

test("finance chat catalog registers viewer red packet, receiver transfer and ledger states", () => {
  for (const id of [
    "redpacket-detail-viewer-claimed",
    "redpacket-detail-claiming",
    "redpacket-detail-unknown-result",
    "redpacket-detail-group-random-completed",
    "caibi-transfer-receiver-accepted",
    "caibi-ledger-loading",
    "caibi-ledger-empty",
    "caibi-ledger-error",
    "caibi-ledger-paged",
    "caibi-transaction-detail"
  ]) assert.equal(getScreen(id).id, id);
});
