import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';

const modulePath = new URL('../src/download-network-selector.js', import.meta.url);
const selector = existsSync(modulePath) ? await import(modulePath) : {};
const selectDownloadRoute = selector.selectDownloadRoute;
const candidates = [
  { id: 'cdn', url: 'https://approved.example.test/downloads/version.apk' },
  { id: 'direct', url: 'https://www.example.test/downloads/version.apk' },
];
const bytes = 262144;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function response({ total = bytes, size = Math.min(bytes, total), status = 206,
  range = `bytes 0-${size - 1}/${total}`, type = 'application/vnd.android.package-archive',
  chunks = [new Uint8Array(size)], bodyDelay = 0, state = {} } = {}) {
  state.reads = 0; state.cancelled = 0; state.released = 0;
  let position = 0;
  return {
    status,
    headers: new Headers({ 'Content-Range': range, 'Content-Type': type }),
    body: {
      cancel() { state.cancelled++; return Promise.resolve(); },
      getReader() {
        return {
          async read() {
            state.reads++;
            if (position === 0 && bodyDelay) await delay(bodyDelay);
            return position < chunks.length ? { value: chunks[position++], done: false } : { done: true };
          },
          cancel() { state.cancelled++; return Promise.resolve(); },
          releaseLock() { state.released++; },
        };
      },
    },
  };
}

function fetcher(plans, requests = []) {
  const rounds = new Map();
  return async (url, options) => {
    requests.push({ url, options });
    const id = candidates.find((item) => item.url === url).id;
    const round = rounds.get(id) ?? 0; rounds.set(id, round + 1);
    const plan = plans[id]?.[round] ?? {};
    if (plan.headerDelay) await delay(plan.headerDelay);
    if (plan.error) throw new Error('sensitive raw network detail');
    return response(plan);
  };
}

function run(plans, options = {}) {
  return selectDownloadRoute({ candidates, artifactBytes: bytes, fetchImpl: fetcher(plans), ...options });
}

test('exports the approved network selector', () => {
  assert.equal(typeof selectDownloadRoute, 'function', 'bounded download route selector is missing');
});

test('one failed round excludes a fast route; stable slower route wins', async () => {
  const result = await run({ cdn: [{}, { error: true }], direct: [{ headerDelay: 15 }, { headerDelay: 15 }] });
  assert.equal(result.id, 'direct'); assert.equal(result.url, candidates[1].url);
  assert.equal(result.reason, 'fastest-stable');
  assert.equal(result.metrics.find((item) => item.id === 'cdn').status, 'failed');
  assert.doesNotMatch(JSON.stringify(result.metrics), /https|sensitive|network detail/);
});

test('throughput including body completion wins over shortest header latency', async () => {
  const result = await run({ cdn: [{ headerDelay: 1, bodyDelay: 100 }, { headerDelay: 1, bodyDelay: 100 }],
    direct: [{ headerDelay: 20 }, { headerDelay: 20 }] });
  assert.equal(result.id, 'direct');
});

test('uses the slower round rather than fastest peak throughput', async () => {
  const result = await run({ cdn: [{ headerDelay: 1 }, { headerDelay: 100 }],
    direct: [{ headerDelay: 20 }, { headerDelay: 20 }] });
  assert.equal(result.id, 'direct');
});

test('routes run in parallel but each second sample waits for its first body to finish', async () => {
  const requests = []; const pending = [];
  const resultPromise = selectDownloadRoute({ candidates, artifactBytes: bytes,
    fetchImpl: (url, options) => { requests.push({ url, options }); return new Promise((resolve) => pending.push(resolve)); } });
  assert.equal(requests.length, 2);
  assert.notEqual(requests[0].url, requests[1].url);
  pending.slice(0, 2).forEach((resolve) => resolve(response()));
  await delay(0);
  assert.equal(requests.length, 4);
  for (const { options } of requests) {
    assert.equal(options.headers.Range, 'bytes=0-262143');
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store'); assert.equal(options.method, 'GET');
  }
  pending.slice(2).forEach((resolve) => resolve(response()));
  const result = await resultPromise;
  assert.equal(result.metrics.flatMap((item) => item.rounds).reduce((sum, item) => sum + item.bytes, 0), 1048576);
});

test('all failed routes fall back to the exact direct input URL', async () => {
  const result = await run({ cdn: [{ error: true }, { error: true }], direct: [{ error: true }, { error: true }] });
  assert.deepEqual([result.id, result.url, result.reason], ['direct', candidates[1].url, 'fallback']);
});

test('a usable route with first-byte latency beyond two seconds still qualifies', async () => {
  const result = await run({cdn:[{headerDelay:2200},{headerDelay:2200}],
    direct:[{error:true}]});
  assert.equal(result.id,'cdn');
  assert.equal(result.reason,'fastest-stable');
  assert.ok(result.metrics[0].rounds.every(round=>round.status==='ok'));
});

test('overall deadline aborts noncooperative fetches and resolves fallback', async () => {
  const signals = [];
  const start = performance.now();
  const result = await selectDownloadRoute({ candidates, artifactBytes: bytes, budgetMs: 25,
    fetchImpl: (_, options) => { signals.push(options.signal); return new Promise(() => {}); } });
  assert.equal(result.reason, 'fallback'); assert.ok(performance.now() - start < 500);
  assert.equal(signals.length, 2); assert.ok(signals.every((signal) => signal.aborted));
  assert.ok(result.metrics.every((item) => item.rounds[0].status === 'timeout' && item.rounds[1].status === 'skipped'));
});

test('caller cancellation releases requests and removes its listener', async () => {
  const controller = new AbortController(); let listeners = 0;
  const add = controller.signal.addEventListener.bind(controller.signal);
  const remove = controller.signal.removeEventListener.bind(controller.signal);
  controller.signal.addEventListener = (...args) => { listeners++; return add(...args); };
  controller.signal.removeEventListener = (...args) => { listeners--; return remove(...args); };
  const signals = [];
  const promise = selectDownloadRoute({ candidates, artifactBytes: bytes, signal: controller.signal,
    fetchImpl: (_, options) => { signals.push(options.signal); return new Promise(() => {}); } });
  controller.abort(new Error('caller private reason'));
  const result = await promise;
  assert.equal(result.reason, 'fallback'); assert.equal(listeners, 0);
  assert.ok(signals.every((signal) => signal.aborted));
  assert.doesNotMatch(JSON.stringify(result.metrics), /private reason/);
});

test('pre-aborted signal never starts network requests', async () => {
  const controller = new AbortController(); controller.abort(); let calls = 0;
  const result = await selectDownloadRoute({ candidates, artifactBytes: bytes, signal: controller.signal,
    fetchImpl: () => { calls++; throw new Error(); } });
  assert.equal(calls, 0); assert.equal(result.reason, 'fallback');
});

test('Range ignored or HTML is rejected without reading response body', async () => {
  const states = [{}, {}, {}, {}];
  const result = await run({ cdn: [{ status: 200, state: states[0] }, { status: 200, state: states[1] }],
    direct: [{ type: 'text/html', state: states[2] }, { type: 'text/html', state: states[3] }] });
  assert.equal(result.reason, 'fallback');
  assert.ok([states[0], states[2]].every((state) => state.reads === 0 && state.cancelled === 1));
});

for (const range of ['bytes 1-262144/262144', 'bytes 0-262143/262145', 'bytes 0-262142/262144', 'bytes 0-262143/*']) {
  test(`rejects mismatched Content-Range ${range}`, async () => {
    const result = await run({ cdn: [{ range }, { range }], direct: [{ error: true }, { error: true }] });
    assert.equal(result.reason, 'fallback');
    assert.equal(result.metrics[0].rounds[0].status, 'range');
    assert.equal(result.metrics[0].rounds[1].status, 'skipped');
  });
}

test('short stream does not qualify as successful throughput', async () => {
  const result = await run({ cdn: [{ chunks: [new Uint8Array(42)] }, {}], direct: [{}, {}] });
  assert.equal(result.id, 'direct'); assert.equal(result.metrics[0].rounds[0].status, 'length');
});

test('oversized stream cancels immediately and keeps no more than the byte cap', async () => {
  const state = {};
  const result = await run({ cdn: [{ chunks: [new Uint8Array(bytes + 1)], state }, {}], direct: [{}, {}] });
  assert.equal(result.id, 'direct'); assert.equal(state.reads, 1); assert.equal(state.cancelled, 1);
  assert.equal(result.metrics[0].rounds[0].status, 'oversize');
  assert.ok(result.metrics.flatMap((item) => item.rounds).every((round) => round.bytes <= bytes));
});

test('body stall is aborted and cancelled within overall budget', async () => {
  const state = {};
  const result = await run({ cdn: [{ bodyDelay: 200, state }, { bodyDelay: 200 }], direct: [{}, {}] }, { budgetMs: 25 });
  assert.equal(result.id, 'direct'); assert.equal(state.cancelled, 1);
  assert.equal(result.metrics[0].rounds[0].status, 'timeout');
});

test('small artifact requests its exact range and validates its actual bytes', async () => {
  const requests = [];
  const result = await selectDownloadRoute({ candidates, artifactBytes: 17,
    fetchImpl: fetcher({ cdn: [{ total: 17 }, { total: 17 }], direct: [{ total: 17 }, { total: 17 }] }, requests) });
  assert.ok(requests.every(({ options }) => options.headers.Range === 'bytes=0-16'));
  assert.ok(result.metrics.every((item) => item.rounds.every((round) => round.bytes === 17)));
});

test('equal conservative throughput uses shorter first-byte latency', async () => {
  const times = [0, 0, 5, 1, 20, 20, 20, 20, 25, 21, 40, 40];
  const result = await run({ cdn: [{}, {}], direct: [{}, {}] }, { now: () => times.shift() });
  assert.equal(result.id, 'direct');
  assert.equal(result.metrics[0].minBps, result.metrics[1].minBps);
  assert.ok(result.metrics[1].ttfbMs < result.metrics[0].ttfbMs);
});

test('each request times out at four seconds without waiting for the nine-second budget', async () => {
  const signals = [];
  const started = performance.now();
  const result = await selectDownloadRoute({ candidates, artifactBytes: bytes,
    fetchImpl: (_, options) => { signals.push(options.signal); return new Promise(() => {}); } });
  const elapsed = performance.now() - started;
  assert.ok(elapsed >= 3900 && elapsed < 5500);
  assert.equal(result.reason, 'fallback');
  assert.ok(signals.every((signal) => signal.aborted));
});

test('successful probes remove caller cancellation listener and release all readers', async () => {
  const controller = new AbortController(); let listeners = 0;
  const add = controller.signal.addEventListener.bind(controller.signal);
  const remove = controller.signal.removeEventListener.bind(controller.signal);
  controller.signal.addEventListener = (...args) => { listeners++; return add(...args); };
  controller.signal.removeEventListener = (...args) => { listeners--; return remove(...args); };
  const states = [{}, {}, {}, {}];
  const result = await run({ cdn: [{ state: states[0] }, { state: states[1] }],
    direct: [{ state: states[2] }, { state: states[3] }] }, { signal: controller.signal });
  assert.equal(result.reason, 'fastest-stable'); assert.equal(listeners, 0);
  assert.ok(states.every((state) => state.released === 1 && state.cancelled === 0));
});

test('caller mutation cannot replace a route URL after its verified sample', async () => {
  const mutable = candidates.map((item) => ({ ...item }));
  const pending = [];
  const promise = selectDownloadRoute({ candidates: mutable, artifactBytes: bytes,
    fetchImpl: () => new Promise((resolve) => pending.push(resolve)) });
  mutable[0].url = 'https://unexpected.example.test/other.apk';
  mutable[1].url = 'https://unexpected.example.test/other.apk';
  pending.slice(0, 2).forEach((resolve) => resolve(response()));
  await delay(0);
  pending.slice(2).forEach((resolve) => resolve(response()));
  const result = await promise;
  assert.ok(candidates.some((candidate) => candidate.url === result.url));
});
