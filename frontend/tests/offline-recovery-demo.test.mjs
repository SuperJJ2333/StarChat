import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { getScreen } from "../src/catalog/screens.js";
import { contractFor } from "../src/catalog/contracts.js";

test("offline-recovery catalog exposes cached, empty, and explicit retry states", () => {
  for (const id of [
    "messages-network-connecting",
    "messages-network-service-unavailable",
    "moments-timeline-cached-offline",
    "moments-timeline-no-cache-offline",
    "moments-timeline-explicit-retry",
    "profile-home-cached-offline",
    "profile-home-no-cache-offline"
  ]) {
    assert.equal(getScreen(id).id, id);
  }
});

test("network capsule contract and registry keep retry compatibility with new states", async () => {
  const contract = contractFor("app-network-capsule");
  assert.ok(contract.allowedAttributes.includes("label"));
  assert.ok(contract.allowedAttributes.includes("disabled"));
  assert.ok(contract.allowedStates.includes("offline"));
  assert.ok(contract.allowedStates.includes("reconnecting"));
  assert.ok(contract.allowedStates.includes("connecting"));
  assert.ok(contract.allowedStates.includes("service-unavailable"));
  const registry = JSON.parse(await readFile(
    new URL("../../packages/ui-contracts/changliao-component-registry.json", import.meta.url),
    "utf8"
  ));
  const network = registry.components.find((component) => component.id === "network-capsule");
  assert.deepEqual(network.flutter.props, ["onRetry", "reconnecting", "label", "disabled"]);
  assert.deepEqual(network.flutter.states, ["offline", "reconnecting", "connecting", "serviceUnavailable"]);
});

test("offline demo actions transition the capsule and coalesce the retry dialog", async () => {
  const source = await readFile(new URL("../src/app.js", import.meta.url), "utf8");
  assert.match(source, /function setCapsuleConnecting/u);
  assert.match(source, /action === "retry-network"/u);
  assert.match(source, /action === "moments:refresh"/u);
  assert.match(source, /u-offline-retry-dialog/u);
  assert.match(source, /action === "profile:retry"/u);
  assert.match(source, /action === "dialog-confirm" && offlineRetryDialog/u);
});
