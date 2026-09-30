import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

test('homepage iOS link reaches the current installation page', () => {
  const source = readFileSync(new URL('../src/admin-home.js', import.meta.url), 'utf8');
  const section = source.slice(source.indexOf('function platformButtons()'), source.indexOf('function heroVisual()'));
  assert.match(section, /const ios = element\("a", "land-btn land-btn-primary"\)/);
  assert.match(section, /ios.href = "\/download"/);
  assert.match(section, /企业正式版/);
  assert.doesNotMatch(section, /测试版/);
  assert.doesNotMatch(section, /ios.disabled|即将上线/);
  assert.doesNotMatch(source, /iOS 版本正在准备中/);
});

test('download page advertises the current IPA and retains OTA installation', () => {
  const source = readFileSync(new URL('../download.html', import.meta.url), 'utf8');
  assert.match(source, /0\.4\.25（2194）/);
  assert.match(source, /href="\/downloads\/ios\/ChatFlow-0\.4\.25-2194-enterprise-552a07a4\.ipa" download/);
  assert.match(source, /itms-services:\/\//);
  assert.doesNotMatch(source, /0\.3\.96|2134/);
});

test('download page warns existing users about the new signing team', () => {
  const source = readFileSync(new URL('../download.html', import.meta.url), 'utf8');
  assert.match(source, /本版更换企业签名团队；覆盖旧版可能无法读取本机聊天记录/);
  assert.doesNotMatch(source, /覆盖升级，勿卸载应用，以保留本机聊天记录/);
  const warning = source.indexOf('id="ios-signing-warning"');
  const install = source.indexOf('>安装 iOS 正式版</a>');
  assert.ok(warning >= 0 && warning < install, 'warning must precede the install action');
  assert.match(source, /aria-describedby="ios-signing-warning"/);
  assert.match(source, /download\.css\?v=20260928-ios13/);
  const css = readFileSync(new URL('../src/styles/download.css', import.meta.url), 'utf8');
  const rule = css.match(/\.download-caution \{([^}]*)\}/)?.[1] ?? '';
  assert.match(rule, /color: var\(--admin-ink\)/);
  assert.match(rule, /background:/);
  assert.match(rule, /font-weight: 600/);
});
