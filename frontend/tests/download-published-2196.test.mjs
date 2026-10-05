import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {startDownload} from '../src/download-redirect.js';

const source = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');

test('Android release registry names the published 2202 artifact on both exact routes', () => {
  const release = JSON.parse(source('../downloads/android-release.json'));
  assert.deepEqual(release, {
    platform: 'android', version: '0.4.33', build: 2202,
    artifact_bytes: 82193438,
    sha256: '0e5255a631ceb37c6556f08caf1b7199637d85c5ea6bd050c49cf6d2f8e642c2',
    cdn_url: 'https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.33-build2202-arm64.apk',
    direct_url: 'https://www.liuhetong888.com/downloads/ChatFlow-0.4.33-build2202-arm64.apk',
  });
});

test('download page offers the 2202 direct fallback and the published network selector', () => {
  const html = source('../download.html');
  assert.match(html, /id="android-network-download"[^>]*data-cdn-host="d12fjr06o6tga5\.cloudfront\.net"/);
  assert.match(html, /id="android-direct-download" href="\/downloads\/ChatFlow-0\.4\.33-build2202-arm64\.apk"/);
  assert.match(html, /\/src\/download-redirect\.js\?v=2202-network/);
  assert.match(source('../src/download-redirect.js'), /installAndroidNetworkDownload/);
});

test('published iOS install warning remains visible without an automatic redirect', () => {
  const html = source('../download.html');
  assert.match(html, /0\.4\.25（2194）/);
  assert.match(html, /id="ios-signing-warning"[^>]*>[^<]*更换企业签名团队/);
  assert.match(html, /aria-describedby="ios-signing-warning"/);
  assert.match(html, /ChatFlow-0\.4\.25-2194-enterprise-d532f913\.ipa/);
  assert.doesNotMatch(html, /已有版本请直接覆盖升级/);
  assert.match(source('../src/styles/download.css'), /\.download-caution[^\n]*border-left/);
  const location = {search: '?install=1', assign() { assert.fail('iOS install must wait for a deliberate click'); }};
  const status = {textContent: ''};
  startDownload(location, {userAgent: 'iPhone'}, status);
  assert.match(status.textContent, /更换企业签名团队/);
});
