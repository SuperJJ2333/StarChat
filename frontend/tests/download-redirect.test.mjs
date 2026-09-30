import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {downloadDestination, startDownload} from '../src/download-redirect.js';

const ios = {userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X)', platform: 'iPhone'};
const android = {userAgent: 'Mozilla/5.0 (Linux; Android 14)', platform: 'Linux armv8l'};
test('legacy bridge routes iPhone to OTA and Android to its existing APK', () => {
  assert.match(downloadDestination('?install=1', ios), /^itms-services:\/\/.*manifest\.plist/);
  assert.equal(downloadDestination('?install=1', android), '/downloads/latest-arm64.apk');
});
test('iPad desktop UA uses OTA, desktop and unknown browsers stay on choices', () => {
  assert.match(downloadDestination('?install=1', {userAgent:'Mozilla/5.0 (Macintosh)', platform:'MacIntel', maxTouchPoints:5}), /^itms-services:/);
  assert.equal(downloadDestination('?install=1', {userAgent:'Mozilla/5.0 (Windows NT 10.0)', platform:'Win32'}), null);
  assert.equal(downloadDestination('?install=1', {}), null);
});
test('no implicit install, no platform mismatch, no caller-controlled destinations', () => {
  assert.equal(downloadDestination('', ios), null);
  assert.equal(downloadDestination('?platform=ios&install=1', android), null);
  assert.equal(downloadDestination('?platform=android&install=1', ios), null);
  assert.equal(downloadDestination('?platform=other&install=1', ios), null);
  assert.match(downloadDestination('?platform=ios&install=1&url=https://evil.invalid', ios), /^itms-services:\/\/.*www\.liuhetong888\.com/);
});
test('iOS install query shows the signing warning and waits for an explicit tap', () => {
  const status = {textContent:''};
  let assignments = 0;
  startDownload({search:'?platform=ios&install=1', assign(){assignments += 1;}}, ios, status);
  assert.equal(assignments, 0);
  assert.match(status.textContent, /更换企业签名团队/);
  const page = readFileSync(new URL('../download.html', import.meta.url), 'utf8');
  assert.match(page, /download-redirect\.js\?v=2194-network/);
});
test('blocked Android browser launch keeps the page and manual fallback usable', () => {
  const status = {textContent:''};
  assert.doesNotThrow(() => startDownload({search:'?install=1', assign(){throw new Error('blocked');}}, android, status));
  assert.match(status.textContent, /点击/);
  let target;
  startDownload({search:'?install=1', assign(value){target=value;}}, android, status);
  assert.equal(target, '/downloads/latest-arm64.apk');
  assert.match(status.textContent, /点击/);
});
