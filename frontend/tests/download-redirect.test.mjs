import assert from 'node:assert/strict';
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
test('blocked browser launch keeps the page and manual fallback usable', () => {
  const status = {textContent:''};
  assert.doesNotThrow(() => startDownload({search:'?install=1', assign(){throw new Error('blocked');}}, ios, status));
  assert.match(status.textContent, /点击/);
  let target;
  startDownload({search:'?install=1', assign(value){target=value;}}, ios, status);
  assert.match(target, /^itms-services:/);
  assert.match(status.textContent, /点击/);
});
