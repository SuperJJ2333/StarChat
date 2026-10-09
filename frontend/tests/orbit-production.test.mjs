import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read = file => readFileSync(new URL(`../${file}`,import.meta.url),'utf8');
test('published landing uses reviewed design and production navigation',()=>{
  const home=read('home.html');
  assert.match(home,/orbit-20261005-v1\/scene.js/);
  assert.match(home,/href="\/download"/);
  assert.doesNotMatch(home,/设计预览|href="download.html"|href="index.html"/);
});
test('published iOS preserves exact signed package and warning before install',()=>{
  const page=read('download.html');
  assert.match(page,/0\.4\.36（2205）/);
  assert.match(page,/href="\/downloads\/ios\/ChatFlow-0\.4\.36-2205-enterprise-a122af83\.ipa" download/);
  assert.match(page,/aria-describedby="ios-signing-warning"/);
  assert.match(page,/itms-services:\/\//);
  assert.ok(page.indexOf('id="ios-signing-warning"')<page.indexOf('>安装 iOS 正式版</a>'));
});
test('published Android preserves network selector and current direct route',()=>{
  const page=read('download.html');
  assert.match(page,/id="android-network-download"[^>]*data-cdn-host="d12fjr06o6tga5.cloudfront.net"/);
  assert.match(page,/id="android-direct-download" href="\/downloads\/ChatFlow-0\.4\.44-build2213-arm64.apk"/);
  assert.match(page,/download-redirect.js\?v=2213-network/);
  assert.match(page,/id="download-status" role="status"/);
  assert.doesNotMatch(page,/设计预览/);
});
