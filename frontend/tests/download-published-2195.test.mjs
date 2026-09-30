import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {startDownload} from '../src/download-redirect.js';

const source = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');

test('Android release registry names the published 2195 artifact on both exact routes', () => {
  const release = JSON.parse(source('../downloads/android-release.json'));
  assert.deepEqual(release, {
    platform: 'android', version: '0.4.26', build: 2195,
    artifact_bytes: 81914910,
    sha256: 'f56d3cc19f4b36bd660421165ae4a4446542307e0f966c86cf78d9b8abf228b4',
    cdn_url: 'https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.26-build2195-arm64.apk',
    direct_url: 'https://www.liuhetong888.com/downloads/ChatFlow-0.4.26-build2195-arm64.apk',
  });
});

test('download page offers the 2195 direct fallback and the published network selector', () => {
  const html = source('../download.html');
  assert.match(html, /id="android-network-download"[^>]*data-cdn-host="d12fjr06o6tga5\.cloudfront\.net"/);
  assert.match(html, /id="android-direct-download" href="\/downloads\/ChatFlow-0\.4\.26-build2195-arm64\.apk"/);
  assert.match(html, /\/src\/download-redirect\.js\?v=2195-network/);
  assert.match(source('../src/download-redirect.js'), /installAndroidNetworkDownload/);
});

test('published iOS install warning remains visible without an automatic redirect', () => {
  const html = source('../download.html');
  assert.match(html, /0\.4\.25（2194）/);
  assert.match(html, /id="ios-signing-warning"[^>]*>[^<]*更换企业签名团队/);
  assert.match(html, /aria-describedby="ios-signing-warning"/);
  assert.match(html, /ChatFlow-0\.4\.25-2194-enterprise-552a07a4\.ipa/);
  assert.doesNotMatch(html, /已有版本请直接覆盖升级/);
  assert.match(source('../src/styles/download.css'), /\.download-caution[^\n]*border-left/);
  const location = {search: '?install=1', assign() { assert.fail('iOS install must wait for a deliberate click'); }};
  const status = {textContent: ''};
  startDownload(location, {userAgent: 'iPhone'}, status);
  assert.match(status.textContent, /更换企业签名团队/);
});
