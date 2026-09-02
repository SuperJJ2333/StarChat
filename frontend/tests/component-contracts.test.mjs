import test from "node:test";
import assert from "node:assert/strict";
import { componentContracts } from "../src/catalog/contracts.js";

const mappedTags = [
  "app-action-button",
  "app-list-tile",
  "app-avatar",
  "app-identity-header",
  "app-message-bubble",
  "app-voice-bubble",
  "app-attachment-tile",
  "app-composer",
  "app-red-packet-card",
  "app-status-chip",
  "app-dialog",
  "app-action-sheet",
  "app-toast",
  "app-empty-state",
  "app-network-capsule",
  "app-moment-tile",
  "app-moment-grid"
];

test("all approved HTML to Figma component mappings have contracts", () => {
  const tags = componentContracts.map((contract) => contract.tagName);
  for (const tag of mappedTags) assert.ok(tags.includes(tag), `missing ${tag}`);
});

test("component contracts use unique strict names and shallow signatures", () => {
  const tags = new Set();
  const roots = new Set();

  for (const contract of componentContracts) {
    assert.match(contract.tagName, /^app-[a-z0-9]+(?:-[a-z0-9]+)*$/u);
    assert.match(contract.rootClass, /^c-[a-z0-9]+(?:-[a-z0-9]+)*$/u);
    assert.ok(!tags.has(contract.tagName), `duplicate tag ${contract.tagName}`);
    assert.ok(!roots.has(contract.rootClass), `duplicate root ${contract.rootClass}`);
    assert.ok(Object.isFrozen(contract.allowedAttributes));
    assert.ok(Object.isFrozen(contract.allowedStates));
    assert.ok(Object.isFrozen(contract.domSignature));
    for (const selector of contract.domSignature) {
      assert.equal(typeof selector, "string");
      assert.ok(selector.split(">").length <= 4, `${selector} is deeper than four levels`);
    }
    tags.add(contract.tagName);
    roots.add(contract.rootClass);
  }
});

test("every declared component contract has a browser registration", async () => {
  globalThis.HTMLElement ??= class {};
  globalThis.customElements ??= {
    definitions: new Map(),
    get(name) { return this.definitions.get(name); },
    define(name, implementation) { this.definitions.set(name, implementation); }
  };
  const { registerComponents } = await import("../src/components/register.js");
  assert.doesNotThrow(() => registerComponents());
  for (const contract of componentContracts) {
    assert.ok(customElements.get(contract.tagName), `missing registration: ${contract.tagName}`);
  }
});
