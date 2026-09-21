import crypto from 'node:crypto';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const origin = 'https://api.appstoreconnect.apple.com';
const bundle = 'com.liuhetong.liuhetongMobile';
const existingInternalGroup = '6c3548a1-b45d-41c7-b4b1-e7a567d15081';

export function installable(build, detail, assigned, group = existingInternalGroup) {
  return build.attributes.processingState === 'VALID' && build.attributes.expired === false &&
    ['READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'].includes(detail.internalBuildState) &&
    assigned.some(item => item.id === group);
}

export function nextBuild(builds, minimum = 2145) {
  return Math.max(minimum, ...builds.map(b => {
    const value = b.attributes?.version;
    if (!/^\d+$/.test(value ?? '')) throw new Error('APPLE_BUILD: NON_INTEGER_VERSION');
    return Number(value) + 1;
  }));
}

function token() {
  const env = process.env;
  for (const name of ['APPSTORE_KEY_ID', 'APPSTORE_ISSUER_ID', 'APPSTORE_PRIVATE_KEY']) {
    if (!env[name]) throw new Error('APPLE_CONFIG: MISSING_' + name);
  }
  let key;
  try { key = crypto.createPrivateKey(env.APPSTORE_PRIVATE_KEY); }
  catch { throw new Error('APPLE_CONFIG: INVALID_PRIVATE_KEY'); }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails.namedCurve !== 'prime256v1') {
    throw new Error('APPLE_CONFIG: EXPECTED_EC_P256');
  }
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const input = encode({ alg: 'ES256', kid: env.APPSTORE_KEY_ID, typ: 'JWT' }) + '.' +
    encode({ iss: env.APPSTORE_ISSUER_ID, iat: now - 10, exp: now + 300, aud: 'appstoreconnect-v1' });
  return input + '.' + crypto.sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
}

async function request(path, options = {}) {
  const url = new URL(path, origin);
  if (url.origin !== origin) throw new Error('APPLE_API: UNEXPECTED_ORIGIN');
  let response;
  try {
    response = await fetch(url, {
      method: options.method ?? 'GET',
      body: options.body ? JSON.stringify(options.body) : undefined,
      headers: { Authorization: 'Bearer ' + token(), 'Content-Type': 'application/json' },
      redirect: 'error', signal: AbortSignal.timeout(30000),
    });
  } catch { throw new Error('APPLE_API: NETWORK_OR_AUTH_CONFIGURATION_ERROR'); }
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    const code = String(body.errors?.[0]?.code ?? '').replace(/[^A-Z0-9_]/g, '_');
    throw new Error('APPLE_API: HTTP_' + response.status + (code ? '_' + code : ''));
  }
  if (response.status === 204) return {};
  try { return await response.json(); }
  catch { throw new Error('APPLE_API: INVALID_JSON'); }
}

async function list(path) {
  const data = [];
  for (let page = 0; path && page < 20; page++) {
    const body = await request(path);
    if (!Array.isArray(body.data)) throw new Error('APPLE_API: INVALID_COLLECTION');
    data.push(...body.data);
    path = body.links?.next;
  }
  if (path) throw new Error('APPLE_API: PAGINATION_LIMIT');
  return data;
}

export async function main(mode) {
  const apps = await list('/v1/apps?' + new URLSearchParams({ 'filter[bundleId]': bundle, limit: '2' }));
  if (apps.length !== 1 || apps[0].attributes.bundleId !== bundle) throw new Error('APPLE_APP: BUNDLE_NOT_UNIQUE');
  const appId = apps[0].id;
  const groups = await list(`/v1/apps/${appId}/betaGroups?limit=200`);
  const safeGroups = groups.map(g => ({ id: g.id, name: g.attributes.name,
    internal: g.attributes.isInternalGroup, publicLinkEnabled: g.attributes.publicLinkEnabled,
    publicLink: g.attributes.publicLinkEnabled ? g.attributes.publicLink : null }));
  const builds = await list('/v1/builds?' + new URLSearchParams({ 'filter[app]': appId, limit: '200', sort: '-uploadedDate' }));
  if (mode === 'preflight') {
    const build = nextBuild(builds);
    console.log(JSON.stringify({ appId, bundle, nextBuild: build, groups: safeGroups }));
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `app_id=${appId}\nbuild=${build}\n`);
    return;
  }
  if (!['status', 'distribute'].includes(mode)) throw new Error('APPLE_MODE: INVALID');
  const wanted = process.env.TESTFLIGHT_BUILD;
  if (!/^\d+$/.test(wanted ?? '')) throw new Error('APPLE_BUILD: REQUIRED');
  const matches = builds.filter(b => b.attributes.version === wanted);
  if (matches.length !== 1) {
    console.log(JSON.stringify({ build: wanted, state: matches.length ? 'AMBIGUOUS' : 'NOT_YET_VISIBLE', groups: safeGroups }));
    process.exitCode = 75;
    return;
  }
  const build = matches[0];
  console.log(JSON.stringify({ build: wanted, buildId: build.id,
    processingState: build.attributes.processingState, expired: build.attributes.expired,
    stage: 'READ_BUILD_BETA_DETAIL' }));
  const detail = await request(`/v1/builds/${build.id}/buildBetaDetail`);
  console.log(JSON.stringify({ build: wanted, beta: detail.data?.attributes,
    groupId: existingInternalGroup, stage: 'READ_INTERNAL_GROUP_BUILDS' }));
  const group = safeGroups.find(g => g.id === existingInternalGroup && g.internal);
  if (!group) throw new Error('APPLE_GROUP: EXPECTED_INTERNAL_GROUP_UNAVAILABLE');
  const groupBuilds = await list(`/v1/betaGroups/${existingInternalGroup}/builds?limit=200`);
  // Group membership is identified by Apple's build resource ID, not its
  // display version, which may also occur in another version train.
  const assigned = groupBuilds.some(item => item.id === build.id) ? [{ id: group.id }] : [];
  console.log(JSON.stringify({ build: wanted, buildId: build.id, processingState: build.attributes.processingState,
    expired: build.attributes.expired, beta: detail.data?.attributes,
    assignedGroupIds: assigned.map(g => g.id), groups: safeGroups }));
  if (installable(build, detail.data?.attributes ?? {}, assigned)) return;
  if (build.attributes.processingState === 'PROCESSING') { process.exitCode = 75; return; }
  if (build.attributes.processingState !== 'VALID' || build.attributes.expired) {
    throw new Error('APPLE_BUILD: INVALID_OR_EXPIRED');
  }
  if (mode === 'distribute') {
    const state = detail.data?.attributes?.internalBuildState;
    if (['READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'].includes(state)) {
      if (!assigned.some(item => item.id === existingInternalGroup)) {
        await request(`/v1/betaGroups/${existingInternalGroup}/relationships/builds`, {
          method: 'POST', body: { data: [{ type: 'builds', id: build.id }] },
        });
        console.log('APPLE_GROUP: EXISTING_INTERNAL_TEST_GROUP_ASSIGNED');
      }
    }
  }
  // Apple processing/compliance and internal group availability are separate from upload success.
  // In particular, never invent an encryption declaration to make a build available.
  process.exitCode = 75;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv[2]).catch(error => {
    const message = error.message;
    console.error(/^[A-Z_]+: [A-Z0-9_]+$/.test(message) ? message : 'APPLE_API: UNEXPECTED_FAILURE');
    process.exitCode = 1;
  });
}
