import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);

function variableNames(source) {
  return [...source.matchAll(/(--[a-z0-9-]+)\s*:/gu)].map((match) => match[1]);
}

function themeBlock(source, theme) {
  const match = source.match(new RegExp(`\\[data-theme="${theme}"\\]\\s*\\{([^}]+)\\}`, "u"));
  assert.ok(match, `missing ${theme} theme block`);
  return match[1];
}

test("light and dark themes expose the same semantic color keys", async () => {
  const source = await readFile(new URL("src/styles/tokens.css", root), "utf8");
  const light = variableNames(themeBlock(source, "light")).sort();
  const dark = variableNames(themeBlock(source, "dark")).sort();

  assert.deepEqual(dark, light);
  assert.deepEqual(light, [
    "--color-brand-pressed",
    "--color-brand-primary",
    "--color-bubble-incoming",
    "--color-bubble-outgoing",
    "--color-danger",
    "--color-divider",
    "--color-on-accent",
    "--color-page-background",
    "--color-red-packet-muted",
    "--color-scrim",
    "--color-social-link",
    "--color-surface-elevated",
    "--color-surface-primary",
    "--color-text-primary",
    "--color-text-secondary",
    "--color-text-tertiary",
    "--color-warning"
  ]);
});

test("red packet muted token matches Flutter in both themes", async () => {
  const css = await readFile(new URL("src/styles/tokens.css", root), "utf8");
  const flutter = await readFile(
    new URL("../apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart", root),
    "utf8"
  );

  for (const theme of ["light", "dark"]) {
    assert.match(
      themeBlock(css, theme),
      /--color-red-packet-muted:\s*#f2b7a8;/u,
      `${theme} red packet muted token drifted`
    );
  }
  assert.match(
    flutter,
    /static const redPacketMuted = Color\(0xFFF2B7A8\);/u
  );
});

test("index loads the approved style layers in fixed order", async () => {
  const html = await readFile(new URL("index.html", root), "utf8");
  const styles = [...html.matchAll(/<link rel="stylesheet" href="([^"]+)">/gu)]
    .map((match) => match[1]);

  assert.deepEqual(styles, [
    "/src/styles/reset.css",
    "/src/styles/tokens.css",
    "/src/styles/primitives.css",
    "/src/styles/components.css",
    "/src/styles/gallery.css"
  ]);
});
