import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { nextBuild, installable, main } from '../../scripts/testflight_status.mjs';
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

const internalGroup = '6c3548a1-b45d-41c7-b4b1-e7a567d15081';
const groupBuildsPath = `/v1/betaGroups/${internalGroup}/builds?limit=200`;

function appleFixture(t, { state = 'IN_BETA_TESTING', assigned = false, paginate = false } = {}) {
  const priorExit = process.exitCode;
  const values = {
    APPSTORE_PRIVATE_KEY: crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
      .privateKey.export({ type: 'pkcs8', format: 'pem' }),
    APPSTORE_KEY_ID: 'TEST_KEY', APPSTORE_ISSUER_ID: 'TEST_ISSUER', TESTFLIGHT_BUILD: '2145',
  };
  const previous = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  process.exitCode = 0;
  t.after(() => {
    process.exitCode = priorExit;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });
  const calls = [];
  const logs = [];
  t.mock.method(console, 'log', value => logs.push(value));
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url.origin, 'https://api.appstoreconnect.apple.com');
    const path = url.pathname + url.search;
    calls.push({ path, method: options.method, body: options.body && JSON.parse(options.body) });
    let body;
    if (url.pathname === '/v1/apps') {
      body = { data: [{ id: 'app-id', attributes: { bundleId: 'com.liuhetong.liuhetongMobile' } }] };
    } else if (path === '/v1/apps/app-id/betaGroups?limit=200') {
      body = { data: [{ id: internalGroup, attributes: { name: 'TEST', isInternalGroup: true } }] };
    } else if (url.pathname === '/v1/builds') {
      body = { data: [{ id: 'exact-build-id', attributes: { version: '2145', processingState: 'VALID', expired: false } }] };
    } else if (path === '/v1/builds/exact-build-id/buildBetaDetail') {
      body = { data: { attributes: { internalBuildState: state } } };
    } else if (path === groupBuildsPath) {
      // Another build can share the display version; only resource ID proves membership.
      body = { data: [{ id: 'other-build-id', attributes: { version: '2145' } }] };
      if (paginate) body.links = { next: `https://api.appstoreconnect.apple.com/v1/betaGroups/${internalGroup}/builds?cursor=next` };
      else if (assigned) body.data.push({ id: 'exact-build-id' });
    } else if (path === `/v1/betaGroups/${internalGroup}/builds?cursor=next`) {
      body = { data: assigned ? [{ id: 'exact-build-id' }] : [] };
    } else if (path === `/v1/betaGroups/${internalGroup}/relationships/builds` && options.method === 'POST') {
      return new Response(null, { status: 204 });
    } else {
      return new Response(JSON.stringify({ errors: [{ code: 'FORBIDDEN' }] }), { status: 403 });
    }
    assert.equal(options.method, 'GET');
    return new Response(JSON.stringify(body), { status: 200 });
  });
  return { calls, logs };
}

test('status reads existing group builds with pagination and matches exact resource ID', async t => {
  const { calls, logs } = appleFixture(t, { assigned: true, paginate: true });
  await main('status');
  assert.equal(process.exitCode, 0);
  assert.ok(calls.some(call => call.path === groupBuildsPath));
  assert.ok(calls.some(call => call.path.endsWith('/builds?cursor=next')));
  assert.ok(calls.every(call => call.method === 'GET'));
  assert.ok(logs.some(log => log.includes('READ_INTERNAL_GROUP_BUILDS')));
  assert.deepEqual(JSON.parse(logs.at(-1)).assignedGroupIds, [internalGroup]);
});

test('same display version in the group does not count as the exact build', async t => {
  const { calls, logs } = appleFixture(t);
  await main('status');
  assert.equal(process.exitCode, 75);
  assert.deepEqual(JSON.parse(logs.at(-1)).assignedGroupIds, []);
  assert.ok(calls.every(call => call.method === 'GET'));
});

test('distribute only associates the exact build with the existing internal group', async t => {
  const { calls } = appleFixture(t);
  await main('distribute');
  assert.equal(process.exitCode, 75); // A subsequent read confirms membership.
  assert.deepEqual(calls.filter(call => call.method !== 'GET'), [{
    path: `/v1/betaGroups/${internalGroup}/relationships/builds`, method: 'POST',
    body: { data: [{ type: 'builds', id: 'exact-build-id' }] },
  }]);
});

test('missing export compliance remains pending without any write even when assigned', async t => {
  const { calls } = appleFixture(t, { assigned: true, state: 'MISSING_EXPORT_COMPLIANCE' });
  await main('distribute');
  assert.equal(process.exitCode, 75);
  assert.ok(calls.every(call => call.method === 'GET'));
});
