import test from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

const sourceRoot = new URL("../src/", import.meta.url);

async function sourceFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const url = new URL(`${entry.name}${entry.isDirectory() ? "/" : ""}`, directory);
    return entry.isDirectory() ? sourceFiles(url) : [url];
  }));
  return nested.flat().filter((url) => /\.(?:css|js)$/u.test(url.pathname));
}

test("source uses no private styling or shadow DOM escape hatches", async () => {
  const files = await sourceFiles(sourceRoot);
  assert.ok(files.length >= 5, "expected the five approved style layers");

  for (const file of files) {
    const source = await readFile(file, "utf8");
    assert.doesNotMatch(source, /!important/u, `${file.pathname} uses !important`);
    assert.doesNotMatch(source, /attachShadow/u, `${file.pathname} uses Shadow DOM`);
    assert.doesNotMatch(source, /style\s*=/u, `${file.pathname} uses inline styles`);
    assert.doesNotMatch(source, /https?:\/\//u, `${file.pathname} uses an external URL`);
    if (!file.pathname.endsWith("/tokens.css")) {
      assert.doesNotMatch(source, /#[0-9a-f]{3,8}\b/iu, `${file.pathname} hard-codes a color`);
      assert.doesNotMatch(source, /\b(?:rgb|rgba|hsl|hsla)\(/iu, `${file.pathname} hard-codes a color function`);
    }
  }
});

test("index has no embedded or inline styles", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.doesNotMatch(html, /<style\b/iu);
  assert.doesNotMatch(html, /\sstyle\s*=/iu);
});
