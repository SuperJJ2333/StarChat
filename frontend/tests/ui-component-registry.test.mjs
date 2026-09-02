import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { componentContracts } from "../src/catalog/contracts.js";

const registry = JSON.parse(await readFile(new URL("../../packages/ui-contracts/changliao-component-registry.json", import.meta.url)));

test("Flutter–HTML–Figma registry names every HTML component contract", () => {
  const tags = new Set(componentContracts.map(({ tagName }) => tagName));
  for (const component of registry.components) {
    assert.ok(tags.has(component.html.tag), `${component.id}: missing ${component.html.tag}`);
  }
  assert.equal(registry.figma.expectedScreenCount, 330);
});
