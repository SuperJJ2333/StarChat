import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {getScreen} from '../src/catalog/screens.js';

test('avatar and moments reuse album and editor demo states', () => {
  const profile = readFileSync(new URL('../src/screens/profile.js', import.meta.url),'utf8');
  const moments = readFileSync(new URL('../src/screens/moments.js', import.meta.url),'utf8');
  assert.match(profile, /app-image-editor/);
  assert.match(profile, /avatar-mode/);
  assert.match(moments, /label: "相册"/);
  assert.ok(getScreen('moments-composer-video'));
  assert.ok(getScreen('moments-composer-video-too-large'));
});
