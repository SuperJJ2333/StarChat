import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const chrome = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
].find(existsSync);

async function waitForBrowser(url) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return await response.json();
    } catch { /* browser starting */ }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw Error('headless browser did not become ready');
}

async function connect(url) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once: true});
    socket.addEventListener('error', reject, {once: true});
  });
  let nextId = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(String(event.data));
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(Error(message.error.message));
    else waiter.resolve(message.result);
  });
  return {
    call(method, params = {}) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        pending.set(id, {resolve, reject});
        socket.send(JSON.stringify({id, method, params}));
      });
    },
    close() { socket.close(); }
  };
}

test('real admin home restores a chain view only after owner confirmation and clears it on session replacement',
  {timeout: 45000}, async t => {
    assert.ok(chrome, 'Chrome or Edge is required for the wallet browser regression');
    const port = 4600 + process.pid % 1000;
    const debugPort = 6600 + process.pid % 1000;
    const origin = `http://127.0.0.1:${port}`;
    const server = spawn(process.execPath, ['scripts/serve.mjs'], {
      cwd: new URL('../', import.meta.url), env: {...process.env, PORT: String(port)}, stdio: 'ignore'
    });
    t.after(() => server.kill());
    const deadline = Date.now() + 5000;
    let ready = false;
    while (Date.now() < deadline) {
      try { ready = (await fetch(origin)).ok; if (ready) break; } catch { /* server starting */ }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.ok(ready, 'frontend fixture server became ready');
    const profile = join(tmpdir(), `starchat-wallet-return-${process.pid}`);
    const browser = spawn(chrome, [
      '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
      `--user-data-dir=${profile}`, `--remote-debugging-port=${debugPort}`, 'about:blank'
    ], {stdio: 'ignore'});
    t.after(() => browser.kill());
    await waitForBrowser(`http://127.0.0.1:${debugPort}/json/version`);
    const targets = await waitForBrowser(`http://127.0.0.1:${debugPort}/json`);
    const page = targets.find(target => target.type === 'page');
    assert.ok(page?.webSocketDebuggerUrl, 'browser exposes a page target');
    const devtools = await connect(page.webSocketDebuggerUrl);
    t.after(() => devtools.close());
    await devtools.call('Page.navigate', {url: `${origin}/tests/admin-wallet-composed-return-browser.html`});
    const finishBy = Date.now() + 20000;
    let state;
    while (Date.now() < finishBy) {
      const response = await devtools.call('Runtime.evaluate', {
        expression: `({result:document.body?.dataset.result,stage:document.body?.dataset.stage,diag:document.body?.dataset.diag,epochs:document.body?.dataset.epochs,message:document.querySelector('#result')?.textContent})`,
        returnByValue: true
      });
      state = response.result?.value;
      if (state?.result === 'PASS' || state?.result === 'FAIL') break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(state?.result, 'PASS', `${state?.stage ?? 'unknown'} (${state?.diag ?? 'no progress'}; epochs=${state?.epochs ?? 'unread'}): ${state?.message ?? 'fixture did not finish'}`);
  });
