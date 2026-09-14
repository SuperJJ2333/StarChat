import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/admin-support-panel.js', import.meta.url), 'utf8');
const css = await readFile(new URL('../src/styles/admin-modern.css', import.meta.url), 'utf8');

test('support command fields, action and feedback use their own layout regions', () => {
  for (const name of ['客服管理', '客服点钻派发']) {
    assert.ok(source.includes(`supportForm('${name}'`));
  }
  assert.match(source, /admin-support-field/u);
  assert.match(source, /admin-support-actions/u);
  assert.match(source, /admin-support-feedback/u);
  assert.match(css, /\.admin-modern \.admin-support-panel \.admin-command-form/u);
  assert.match(css, /grid-template-columns:\s*repeat\(auto-fit,\s*minmax\(min\(100%,\s*15rem\),\s*1fr\)\)/u);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*\.admin-modern \.admin-support-panel \.admin-command-form/u);
});
