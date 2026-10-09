import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const source=path=>readFile(new URL(path,import.meta.url),'utf8');

test('wallet workspace labels platform applications separately from chain facts and payout orders',async()=>{
 const home=await source('../src/admin-home.js');
 const dashboard=await source('../src/admin-dashboard.js');
 const payout=await source('../src/admin-manual-wallet-panel.js');
 assert.match(home,/USDT提现与支付/u);
 assert.match(home,/链上观察余额不等于账本可用余额/u);
 assert.match(payout,/用户提现申请/u);
 assert.match(payout,/人工出款订单编号/u);
 assert.match(payout,/链上交易哈希/u);
 for(const route of ['wallet-chain','wallet-payout','wallet-monitor','wallet-owner','wallet-security'])assert.ok(dashboard.includes(`'${route}'`),`navigation includes ${route}`);
 assert.match(dashboard,/aria-controls/u);
 assert.match(dashboard,/route==='wallet'\?'wallet-chain':route/u);
});

test('wallet presentation keeps tables scrollable, details legible and reduced motion respected',async()=>{
 const wallet=await source('../src/styles/admin-wallet.css');
 assert.match(wallet,/\.admin-modern \.admin-wallet-hero/u);
 assert.match(wallet,/\.admin-chain-panel \.admin-table-scroll\s*\{[^}]*overflow-x:\s*auto/u);
 assert.match(wallet,/@media\s*\(max-width:\s*700px\)/u);
 assert.match(wallet,/@media\s*\(prefers-reduced-motion:\s*reduce\)/u);
 assert.match(wallet,/@media\s*\(prefers-contrast:\s*more\)/u);
 assert.match(wallet,/\.admin-modern \.admin-wallet-workspace/u);
});
