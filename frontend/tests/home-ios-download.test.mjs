import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

test('homepage iOS link reaches the current installation page', () => {
  const source = readFileSync(new URL('../src/admin-home.js', import.meta.url), 'utf8');
  const section = source.slice(source.indexOf('function platformButtons()'), source.indexOf('function heroVisual()'));
  assert.match(section, /const ios = element\("a", "land-btn land-btn-primary"\)/);
  assert.match(section, /ios.href = "\/download"/);
  assert.match(section, /0\.4\.7（2173）/);
  assert.match(section, /企业正式版/);
  assert.doesNotMatch(section, /测试版/);
  assert.doesNotMatch(section, /ios.disabled|即将上线/);
  assert.doesNotMatch(source, /iOS 版本正在准备中/);
});

test('download page advertises the current IPA and retains OTA installation', () => {
  const source = readFileSync(new URL('../download.html', import.meta.url), 'utf8');
  assert.match(source, /0\.4\.7（2173）/);
  assert.match(source, /href="\/downloads\/ios\/ChatFlow-0\.4\.7-build2173\.ipa" download/);
  assert.match(source, /itms-services:\/\//);
  assert.doesNotMatch(source, /0\.3\.96|2134/);
});
