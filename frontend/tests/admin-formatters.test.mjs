import test from 'node:test';
import assert from 'node:assert/strict';
import {formatBeijingTime,parseBeijingInput,reasonLabel,statusLabel,actorLabel} from '../src/admin-formatters.js';

test('absolute times have fixed Beijing calendar format across timezone offsets',()=>{
  assert.equal(formatBeijingTime('2026-09-09T18:04:05Z'),'2026-09-10 02:04:05');
  assert.equal(formatBeijingTime('2026-09-10T02:04:05+08:00'),'2026-09-10 02:04:05');
  assert.equal(formatBeijingTime('2026-09-09T18:04:05'),'2026-09-10 02:04:05');
  assert.equal(formatBeijingTime('2026-09-10'),'2026-09-10 00:00:00');
  assert.equal(formatBeijingTime('2026-02-30T12:00:00Z'),'—');
  for(const value of [null,undefined,'invalid',''])assert.equal(formatBeijingTime(value),'—');
});
test('datetime-local filters mean Beijing regardless of the browser timezone',()=>{
  assert.equal(parseBeijingInput('2026-09-10T02:04'),Date.parse('2026-09-09T18:04:00Z'));
  assert.equal(parseBeijingInput(''),undefined);
  assert.ok(Number.isNaN(parseBeijingInput('2026-02-30T12:00')));
});
test('identities and technical codes have readable labels without object coercion',()=>{
  assert.equal(actorLabel({actor_id:'uuid',actor_username:'chat123'}),'chat123');
  assert.equal(actorLabel({actor_id:'uuid'}),'未关联畅聊号');
  assert.equal(reasonLabel('SUPPORT_CAIBI_GRANT'),'客服点钻发放');
  assert.equal(statusLabel('ACTIVE'),'正常');
  assert.doesNotMatch(reasonLabel('FUTURE_CODE'),/FUTURE_CODE/);
});
