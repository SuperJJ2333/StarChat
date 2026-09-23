import test from 'node:test';
import assert from 'node:assert/strict';
import {formatPoints, trendGeometry, refreshCoordinator} from '../src/admin-dashboard.js';

test('staff navigation excludes administrator USDT wallet without broadening permissions',async()=>{
  const {visibleAdminModules}=await import('../src/admin-dashboard.js');
  const modules=[['客服订单','','recharge','admin.finance.read'],['USDT提现与支付','','wallet','admin.withdrawals.read'],['用户管理','','analytics','admin.analytics.read']];
  const context={permissions:['admin.finance.read','admin.withdrawals.read','admin.overview.read'],actor:{roles:['FINANCE_SUPPORT']}};
  assert.equal(typeof visibleAdminModules,'function');
  assert.deepEqual(visibleAdminModules(context,modules).map(x=>x[2]),['recharge']);
  assert.equal(visibleAdminModules({permissions:['*']},modules).length,3);
});

test('point totals preserve cents beyond JavaScript safe integer',()=>{
  assert.equal(formatPoints('100000000000000001.09'),'100,000,000,000,000,001.09');
  assert.equal(formatPoints('-0.01'),'-0.01');
  assert.equal(formatPoints(null),'—');
  assert.equal(formatPoints('invalid'),'—');
});
test('trend uses real values, scales peaks and handles zero and single points',()=>{
  const chart=trendGeometry([{date:'2026-09-07',value:0},{date:'2026-09-08',value:40}]);
  assert.equal(chart.max,40);assert.ok(chart.points[1].y<chart.points[0].y);
  assert.ok(trendGeometry([{date:'2026-09-08',value:0}]).points.every(p=>Number.isFinite(p.x)&&Number.isFinite(p.y)));
  assert.deepEqual(trendGeometry([]).points,[]);
});
test('one refresh joins repeated clicks and isolates partial failures',async()=>{
  let finish,calls=0;const refresh=refreshCoordinator();
  const tasks=[()=>{calls++;return new Promise(r=>{finish=r;});},async()=>{throw Error('offline');}];
  const first=refresh(tasks),second=refresh(tasks);await Promise.resolve();assert.equal(calls,1);finish('done');
  const result=await first;await second;assert.equal(result[0].status,'fulfilled');assert.equal(result[1].status,'rejected');
});
