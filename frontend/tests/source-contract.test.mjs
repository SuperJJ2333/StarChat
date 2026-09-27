import test from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

const sourceRoot = new URL("../src/", import.meta.url);

function checkedInstallerSource(source) {
  const direct="const DIRECT = 'https://www.liuhetong888.com';";
  const cdn='`https://${cdnHost}${path}`';
  assert.equal(source.split(direct).length-1,1,'expected one fixed direct origin declaration');
  assert.equal(source.split(cdn).length-1,1,'expected one validated pinned CDN expression');
  return source.replace(direct,'').replace(cdn,'');
}

test('installer URL exception cannot hide a host suffix or credential redirect',()=>{
  for (const url of ['https://www.liuhetong888.com.evil.invalid',
    'https://www.liuhetong888.com@evil.invalid']) {
    const source="const DIRECT = 'https://www.liuhetong888.com';\n"
      + 'value.cdn_url !== `https://${cdnHost}${path}`;\n'
      + `const foreign = '${url}';`;
    assert.match(checkedInstallerSource(source),/https?:\/\//u);
  }
});

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
    // SVG's standard namespace is an identifier, never a network resource.
    // Enterprise OTA requires an absolute HTTPS manifest on our own download host.
    // Allow only this exact first-party manifest in the download router.
    let checkedSource = file.pathname.endsWith('/download-redirect.js')
      ? source.replaceAll('https://www.liuhetong888.com/downloads/ios/manifest.plist', '')
      : source;
    // Installer routes require absolute URLs. The bootstrap binds both to the
    // published version and one exact page-pinned CDN host; its rejection tests
    // cover credentials, other hosts, mutable aliases and mismatched versions.
    // Keep every other external URL forbidden, including in this same file.
    if (file.pathname.endsWith('/download-network.js')) checkedSource=checkedInstallerSource(checkedSource);
    assert.doesNotMatch(checkedSource.replaceAll('http://www.w3.org/2000/svg',''), /https?:\/\//u, `${file.pathname} uses an external URL`);
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
