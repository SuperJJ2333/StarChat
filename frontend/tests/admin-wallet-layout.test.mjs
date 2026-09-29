import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const source=path=>readFile(new URL(path,import.meta.url),'utf8');

test('wallet workspace labels platform applications separately from chain facts and payout orders',async()=>{
 const home=await source('../src/admin-home.js');
 assert.match(home,/USDT 钱包操作台/u);
 assert.match(home,/托管提现申请记录/u);
 assert.match(home,/托管提现申请编号/u);
 assert.match(home,/人工出款订单编号/u);
 assert.match(home,/链上交易哈希/u);
 assert.match(home,/钱包页面分区/u);
 for(const anchor of ['wallet-chain','wallet-payout','wallet-monitor','wallet-owner','wallet-security'])assert.ok(home.includes(`'${anchor}'`),`navigation includes ${anchor}`);
 assert.match(home,/link\.href=`#\$\{id\}`/u);
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
