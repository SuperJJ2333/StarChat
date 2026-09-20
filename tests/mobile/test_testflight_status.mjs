import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextBuild, installable } from '../../scripts/testflight_status.mjs';
test('new app and existing builds choose a monotonic unused number', () => {
  assert.equal(nextBuild([]), 2145);
  assert.equal(nextBuild([{attributes:{version:'2144'}}]), 2145);
  assert.equal(nextBuild([{attributes:{version:'2151'}},{attributes:{version:'2149'}}]), 2152);
});
test('ambiguous dotted build fails instead of reusing a number', () => {
  assert.throws(() => nextBuild([{attributes:{version:'1.2.3'}}]), /NON_INTEGER_VERSION/);
});

test('processed alone is not TestFlight installation readiness', () => {
  const build = {attributes:{processingState:'VALID', expired:false}};
  const groups = [{id:'test'}];
  assert.equal(installable(build, {internalBuildState:'MISSING_EXPORT_COMPLIANCE'}, groups, 'test'), false);
  assert.equal(installable(build, {internalBuildState:'IN_BETA_TESTING'}, [], 'test'), false);
  assert.equal(installable({...build, attributes:{...build.attributes, expired:true}}, {internalBuildState:'IN_BETA_TESTING'}, groups, 'test'), false);
  assert.equal(installable(build, {internalBuildState:'IN_BETA_TESTING'}, groups, 'test'), true);
});
