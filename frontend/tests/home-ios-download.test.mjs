import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

test('homepage iOS link reaches the current installation page', () => {
  const source = readFileSync(new URL('../src/admin-home.js', import.meta.url), 'utf8');
  const section = source.slice(source.indexOf('function platformButtons()'), source.indexOf('function heroVisual()'));
  assert.match(section, /const ios = element\("a", "land-btn land-btn-primary"\)/);
  assert.match(section, /ios.href = "\/download"/);
  assert.match(section, /0\.3\.81（2085）/);
  assert.doesNotMatch(section, /ios.disabled|即将上线/);
  assert.doesNotMatch(source, /iOS 版本正在准备中/);
});
