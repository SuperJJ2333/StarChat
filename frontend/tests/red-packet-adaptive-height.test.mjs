import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles/components.css", import.meta.url), "utf8");
const rule = (selector) => css.slice(css.indexOf(`${selector} {`)).split("}")[0];
test("red packet keeps its minimum size while header text can grow", () => {
  const card = rule(".c-red-packet");
  const body = rule(".c-red-packet__body");
  assert.match(card, /width: var\(--size-red-packet-width\)/u);
  assert.match(card, /min-height: var\(--size-red-packet-height\)/u);
  assert.doesNotMatch(card, /^\s*height:/mu);
  assert.match(body, /min-height: calc\(var\(--size-red-packet-height\) - var\(--space-xl\)\)/u);
  assert.doesNotMatch(body, /^\s*height:/mu);
  assert.match(rule(".c-red-packet__footer"), /height: var\(--space-xl\)/u);
  const registry = JSON.parse(readFileSync(new URL("../../packages/ui-contracts/changliao-component-registry.json", import.meta.url), "utf8"));
  assert.ok(JSON.stringify(registry).includes("header grows naturally"));
});
