import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { componentContracts } from "../src/catalog/contracts.js";
import { getScreen } from "../src/catalog/screens.js";

const root = new URL("../", import.meta.url);

async function css(...layers) {
  return (await Promise.all(layers.map((layer) => readFile(new URL(`src/styles/${layer}`, root), "utf8")))).join("\n");
}

test("shared gradient divider token keeps the lower alpha and fading ends", async () => {
  const tokens = await readFile(new URL("src/styles/tokens.css", root), "utf8");
  assert.match(tokens, /--divider-fade-alpha:\s*0\.5;/u);
  assert.match(tokens, /--divider-fade-edge-alpha:\s*0;/u);
  assert.match(tokens, /--divider-fade-core-start:\s*18%;/u);
  assert.match(tokens, /--divider-fade-core-end:\s*82%;/u);

  // `[^}]*` 限定在同一规则块内匹配，避免跨块取到另一个主题的渐变。
  const lightMatch = tokens.match(/\.ui-screen\s*\{[^}]*--divider-fade:\s*linear-gradient\(([\s\S]*?)\);/u);
  assert.ok(lightMatch, "light --divider-fade gradient is missing");
  const darkMatch = tokens.match(/\.ui-screen\[data-theme="dark"\]\s*\{[^}]*--divider-fade:\s*linear-gradient\(([\s\S]*?)\);/u);
  assert.ok(darkMatch, "dark --divider-fade gradient is missing");
  const light = lightMatch[1];
  const dark = darkMatch[1];

  for (const [theme, gradient, channel] of [["light", light, "217 217 217"], ["dark", dark, "44 44 44"]]) {
    // 第 0 项是渐变方向（90deg 横向），随后是四个色标。
    const stops = gradient.split(",").map((stop) => stop.trim());
    assert.equal(stops[0], "90deg", `${theme} gradient must run horizontally`);
    stops.shift();
    assert.equal(stops.length, 4, `${theme} gradient must keep four stops`);
    // 两端渐隐到完全透明，中部使用 ALPHA token（低于实心分割线）。
    assert.match(stops[0], new RegExp(`^rgb\\(${channel} / var\\(--divider-fade-edge-alpha\\)\\) 0%$`, "u"), `${theme} left end must fade to transparent`);
    assert.match(stops[3], new RegExp(`^rgb\\(${channel} / var\\(--divider-fade-edge-alpha\\)\\) 100%$`, "u"), `${theme} right end must fade to transparent`);
    assert.match(stops[1], /var\(--divider-fade-alpha\)/u);
    assert.match(stops[2], /var\(--divider-fade-alpha\)/u);
    assert.match(stops[1], /var\(--divider-fade-core-start\)/u);
    assert.match(stops[2], /var\(--divider-fade-core-end\)/u);
  }
});

test("list surfaces paint the gradient divider instead of a solid border", async () => {
  const layers = await css("components.css", "primitives.css", "tokens.css");
  assert.match(layers, /\.c-gradient-divider\s*\{[\s\S]*?background-image:\s*var\(--divider-fade\);/u);
  for (const selector of [".c-list-tile", ".c-contact-row"]) {
    const block = layers.match(new RegExp(`\\${selector}\\s*\\{([\\s\\S]*?)\\}`, "u"));
    assert.ok(block, `${selector} block is missing`);
    assert.match(block[1], /background-color:\s*var\(--color-surface-elevated\);/u);
    assert.match(block[1], /background-image:\s*var\(--divider-fade\);/u);
    assert.doesNotMatch(block[1], /border-bottom/u);
  }
});

test("divider and brand tint tokens match the Flutter token layer", async () => {
  const tokens = await readFile(new URL("src/styles/tokens.css", root), "utf8");
  const flutter = await readFile(new URL("../apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart", root), "utf8");
  assert.match(tokens, /--color-brand-tint:\s*rgb\(7 193 96 \/ 12%\);/u);
  assert.match(flutter, /static const brandTint = Color\(0x1F07C160\);/u);
  for (const line of [
    "static const hairline = 1.0;",
    "static const edgeStartStop = 0.0;",
    "static const coreStart = 0.18;",
    "static const coreEnd = 0.82;",
    "static const edgeEndStop = 1.0;",
    "static const edgeAlpha = 0.0;",
    "static const centerAlpha = 0.5;"
  ]) {
    assert.ok(flutter.includes(line), `Flutter divider token missing: ${line}`);
  }
});

test("app-divider is a registered component with a Flutter counterpart", async () => {
  const contract = componentContracts.find(({ tagName }) => tagName === "app-gradient-divider");
  assert.ok(contract, "app-gradient-divider contract is missing");
  assert.equal(contract.rootClass, "c-gradient-divider");
  const registry = JSON.parse(await readFile(new URL("../packages/ui-contracts/changliao-component-registry.json", root), "utf8"));
  const entry = registry.components.find(({ id }) => id === "gradient-divider");
  assert.ok(entry, "registry entry gradient-divider is missing");
  assert.equal(entry.html.tag, "app-gradient-divider");
  const shared = await readFile(new URL(`../${entry.flutter.file}`, root), "utf8");
  assert.match(shared, new RegExp(`class ${entry.flutter.name}\\b`, "u"));
  assert.match(shared, /LinearGradient/u);
});

test("friend request verification frames are registered in the HTML demo", () => {
  for (const id of ["contacts-verify-pending", "contacts-verify-added", "contacts-verify-rejected"]) {
    assert.equal(getScreen(id).id, id);
  }
  assert.ok(getScreen("contacts-index-default").id);
});
