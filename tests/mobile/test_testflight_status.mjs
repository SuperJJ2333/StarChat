import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextBuild } from '../../scripts/testflight_status.mjs';
test('new app and existing builds choose a monotonic unused number', () => {
  assert.equal(nextBuild([]), 2145);
  assert.equal(nextBuild([{attributes:{version:'2144'}}]), 2145);
  assert.equal(nextBuild([{attributes:{version:'2151'}},{attributes:{version:'2149'}}]), 2152);
});
test('ambiguous dotted build fails instead of reusing a number', () => {
  assert.throws(() => nextBuild([{attributes:{version:'1.2.3'}}]), /NON_INTEGER_VERSION/);
});
