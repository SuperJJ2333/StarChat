import test from 'node:test';
import assert from 'node:assert/strict';
import {createAdminApi} from '../src/admin-api.js';

test('wallet access endpoints are no-store and verification sends only explicit proof', async () => {
  const {api,calls}=fixture();
  assert.equal(typeof api.getWalletAccess,'function');
  await api.getWalletAccess();
  await api.verifyWalletAccess({operation_password:' exact password '});
  await api.revokeWalletAccess();
  assert.deepEqual(calls.map(c=>c.url),['/api/v1/wallet/manual/access','/api/v1/wallet/manual/access/verify','/api/v1/wallet/manual/access/revoke']);
  assert.deepEqual(JSON.parse(calls[1].options.body),{operation_password:' exact password '});
  assert.ok(calls.every(c=>c.options.cache==='no-store'));
});

function fixture() {
  const calls = [];
  const api = createAdminApi({token: 'fixture-token', fetchImpl: async (url, options) => {
    calls.push({url, options});
    return new Response(JSON.stringify({status: 'CLAIMED', amount: '100000.000000'}),
      {headers: {'content-type': 'application/json'}});
  }});
  return {api, calls};
}

test('manual payout reads use actual admin routes and encode cursors', async () => {
  const {api, calls} = fixture();
  await api.getManualPayouts({limit: 20, cursor: 'opaque+cursor/='});
  await api.getManualPayout('order/id');
  assert.equal(calls[0].url, '/api/v1/admin/wallet/manual/payouts?limit=20&cursor=opaque%2Bcursor%2F%3D');
  assert.equal(calls[1].url, '/api/v1/admin/wallet/manual/payouts/order%2Fid');
  for (const call of calls) {
    assert.equal(call.options.headers.Authorization, 'Bearer fixture-token');
    assert.equal(call.options.cache, 'no-store');
  }
});

test('manual payout claim retry preserves caller key and exact digest', async () => {
  const {api, calls} = fixture();
  const body = {expected_digest: 'a'.repeat(64), mfa_proof: '123456'};
  const options = {idempotencyKey: 'claim-once'};
  const first = await api.claimManualPayout('order-1', body, options);
  await api.claimManualPayout('order-1', body, options);
  assert.equal(first.amount, '100000.000000');
  assert.deepEqual(calls[0], calls[1]);
  assert.equal(calls[0].url, '/api/v1/wallet/manual/payouts/order-1/claim');
  assert.equal(calls[0].options.headers['Idempotency-Key'], 'claim-once');
  assert.deepEqual(JSON.parse(calls[0].options.body), body);
});

test('candidate submission and correction remain distinct from settlement', async () => {
  const {api, calls} = fixture();
  const txid = 'b'.repeat(64);
  const result = await api.submitManualPayoutTxid('order-1', {txid}, {idempotencyKey: 'submit-once'});
  await api.correctManualPayoutCandidate('order-1', {txid, reason_code: 'WRONG_LOCATOR', mfa_proof: '234567'}, {idempotencyKey: 'correct-once'});
  assert.equal(result.status, 'CLAIMED');
  assert.equal(calls[0].url, '/api/v1/wallet/manual/payouts/order-1/txid');
  assert.equal(calls[1].url, '/api/v1/wallet/manual/payouts/order-1/correct-candidate');
  assert.equal(JSON.parse(calls[1].options.body).reason_code, 'WRONG_LOCATOR');
});

test('every manual payout command rejects a missing stable key before network access', async () => {
  const {api, calls} = fixture();
  for (const method of ['claimManualPayout', 'submitManualPayoutTxid', 'correctManualPayoutCandidate']) {
    await assert.rejects(api[method]('order-1', {}), /idempotencyKey/);
  }
  assert.equal(calls.length, 0);
});

test('administrator MFA uses shared identity routes', async () => {
  const {api, calls} = fixture();
  await api.getWalletMfaStatus();
  await api.enrollWalletMfa({password: 'fixture-password'}, {idempotencyKey: 'enroll-once'});
  await api.enableWalletMfa({credential_id: 'credential-1', code: '123456'}, {idempotencyKey: 'enable-once'});
  await api.abortWalletMfaEnrollment({credential_id: 'credential-1', password: 'fixture-password'}, {idempotencyKey: 'abort-once'});
  assert.deepEqual(calls.map(call => call.url), ['/api/v1/security/mfa', '/api/v1/security/mfa/enroll', '/api/v1/security/mfa/enable', '/api/v1/security/mfa/abort-pending']);
  assert.equal(calls[0].options.cache, 'no-store');
});
