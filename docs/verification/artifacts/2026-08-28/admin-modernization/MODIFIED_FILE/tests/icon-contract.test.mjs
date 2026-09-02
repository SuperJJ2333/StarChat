import test from "node:test";
import assert from "node:assert/strict";

globalThis.HTMLElement = class {};
const iconModule = await import("../src/icons/icons.js");

const requiredProductIcons = [
  "chat",
  "contact",
  "discovery",
  "me",
  "call",
  "video",
  "microphone",
  "camera",
  "search",
  "settings",
  "wallet",
  "gift"
];

test("icon library provides a production-sized editable outline set", () => {
  assert.ok(iconModule.iconNames.length >= 48, `expected at least 48 icons, got ${iconModule.iconNames.length}`);
  for (const name of requiredProductIcons) {
    assert.ok(iconModule.iconNames.includes(name), `missing product icon ${name}`);
  }

  assert.ok(iconModule.iconDefinitions, "icon definitions must be exported for HTML and Figma parity");
  for (const name of iconModule.iconNames) {
    const definition = iconModule.iconDefinitions[name];
    assert.ok(Array.isArray(definition) && definition.length > 0, `${name} needs editable SVG geometry`);
    for (const primitive of definition) {
      assert.ok(["path", "circle", "rect", "line", "polyline"].includes(primitive.tag), `${name} uses unsupported SVG primitive`);
      assert.equal(typeof primitive.attributes, "object");
    }
  }
});
