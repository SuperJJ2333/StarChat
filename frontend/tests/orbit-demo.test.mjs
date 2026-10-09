import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = name => readFileSync(new URL(`../concepts/orbit/${name}`, import.meta.url), 'utf8');

test('review demo connects landing and download without changing production routes', () => {
  assert.match(read('index.html'), /href="download.html"/);
  assert.match(read('download.html'), /href="index.html"/);
  for (const page of ['index.html', 'download.html']) {
    assert.match(read(page), /name="viewport"/);
    assert.match(read(page), /设计预览/);
  }
});
test('download preview preserves explicit platform choice and enterprise warning', () => {
  const page = read('download.html');
  assert.match(page, /data-platform="android"/);
  assert.match(page, /data-platform="ios"/);
  assert.match(page, /aria-describedby="ios-warning"/);
  assert.match(page, /唯一能读取旧记录的设备/);
  assert.match(page, /https:\/\/www.liuhetong888.com\/download/);
  assert.doesNotMatch(read('ui.js'), /location\.(?:assign|replace)|location\.href\s*=/);
});
test('three scene offers local dependency, motion preference and resource cleanup', () => {
  const scene = read('scene.js');
  assert.match(scene, /vendor\/three/);
  assert.match(scene, /prefers-reduced-motion/);
  assert.match(scene, /IntersectionObserver/);
  assert.match(scene, /webglcontextlost/);
  assert.match(scene, /dispose\(/);
});
