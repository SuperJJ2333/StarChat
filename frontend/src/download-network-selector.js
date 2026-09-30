const SAMPLE_BYTES = 262144;
const REQUEST_MS = 4000;
export const DOWNLOAD_PROBE_BUDGET_MS = 9000;
const BINARY_TYPES = new Set(['application/vnd.android.package-archive', 'application/octet-stream']);

class ProbeFailure extends Error {
  constructor(status) {
    super(status);
    this.status = status;
  }
}

function abortStatus(signal) {
  return signal.reason === 'timeout' ? 'timeout' : 'aborted';
}

// Consume counters only, never retain APK chunks or read an unbounded arrayBuffer.
async function probe(candidate, artifactBytes, fetchImpl, now, overallSignal) {
  const expectedBytes = Math.min(SAMPLE_BYTES, artifactBytes);
  const started = now();
  const controller = new AbortController();
  let bytes = 0;
  let ttfbMs = 0;
  let reader;
  let response;
  let finished = false;
  let cancelled = false;
  const elapsed = () => Math.max(0, now() - started);
  const cancelBody = () => {
    if (cancelled || finished) return;
    cancelled = true;
    try {
      const cancellation = reader ? reader.cancel() : response?.body?.cancel();
      Promise.resolve(cancellation).catch(() => {});
    } catch {
      // Cancellation is best effort; abort still terminates the fetch.
    }
  };
  const forwardAbort = () => controller.abort(abortStatus(overallSignal));
  const abort = () => {
    cancelBody();
    rejectAbort(new ProbeFailure(abortStatus(controller.signal)));
  };
  let rejectAbort;
  const interrupted = new Promise((_, reject) => { rejectAbort = reject; });
  controller.signal.addEventListener('abort', abort, { once: true });
  overallSignal.addEventListener('abort', forwardAbort, { once: true });
  const timer = setTimeout(() => controller.abort('timeout'), REQUEST_MS);
  const checkAbort = () => {
    if (controller.signal.aborted) throw new ProbeFailure(abortStatus(controller.signal));
  };

  try {
    if (overallSignal.aborted) forwardAbort();
    const operation = (async () => {
      checkAbort();
      response = await fetchImpl(candidate.url, {
        method: 'GET', mode: 'cors', credentials: 'omit', cache: 'no-store', redirect: 'error',
        headers: { Range: `bytes=0-${expectedBytes - 1}` }, signal: controller.signal,
      });
      if (controller.signal.aborted) {
        // A noncooperative transport may resolve after the outer race settled.
        cancelled = false;
        cancelBody();
        checkAbort();
      }
      ttfbMs = elapsed();
      if (response.status !== 206) throw new ProbeFailure('http');
      const range = /^bytes\s+0-(\d+)\/(\d+)$/i.exec(response.headers.get('Content-Range') ?? '');
      if (!range || Number(range[1]) !== expectedBytes - 1 || Number(range[2]) !== artifactBytes) {
        throw new ProbeFailure('range');
      }
      const type = (response.headers.get('Content-Type') ?? '').split(';', 1)[0].trim().toLowerCase();
      if (!BINARY_TYPES.has(type)) throw new ProbeFailure('type');
      const length = response.headers.get('Content-Length');
      if (length !== null && (!/^\d+$/.test(length) || Number(length) !== expectedBytes)) {
        throw new ProbeFailure('length');
      }
      if (!response.body?.getReader) throw new ProbeFailure('stream');
      reader = response.body.getReader();
      while (true) {
        const chunk = await reader.read();
        checkAbort();
        if (chunk.done) break;
        if (!(chunk.value instanceof Uint8Array)) throw new ProbeFailure('stream');
        if (chunk.value.byteLength > expectedBytes - bytes) throw new ProbeFailure('oversize');
        bytes += chunk.value.byteLength;
      }
      if (bytes !== expectedBytes) throw new ProbeFailure('length');
      finished = true;
    })();
    await Promise.race([operation, interrupted]);
    const durationMs = elapsed();
    return { status: 'ok', ttfbMs, durationMs, bytes, bps: bytes * 1000 / Math.max(1, durationMs) };
  } catch (error) {
    const status = error instanceof ProbeFailure ? error.status : 'network';
    cancelBody();
    return { status, ttfbMs, durationMs: elapsed(), bytes, bps: 0 };
  } finally {
    clearTimeout(timer);
    overallSignal.removeEventListener('abort', forwardAbort);
    controller.signal.removeEventListener('abort', abort);
    if (!finished) controller.abort('aborted');
    try { reader?.releaseLock(); } catch { /* A cancelled read may still be settling. */ }
  }
}

/**
 * Caller supplies exactly two registry-verified HTTPS URLs for the same artifact.
 * Results and timings stay in memory; no location, account or reporting is used.
 */
export async function selectDownloadRoute({ candidates, artifactBytes,
  fetchImpl = globalThis.fetch, now = () => performance.now(), budgetMs = DOWNLOAD_PROBE_BUDGET_MS, signal } = {}) {
  if (!Array.isArray(candidates) || candidates.length !== 2 ||
      new Set(candidates.map((item) => item.id)).size !== 2 ||
      !candidates.some((item) => item.id === 'cdn') || !candidates.some((item) => item.id === 'direct') ||
      !Number.isSafeInteger(artifactBytes) || artifactBytes <= 0) {
    throw new TypeError('Two verified routes and a positive artifact size are required');
  }
  // Bind the result to the exact URLs verified at entry, even across awaits.
  candidates = candidates.map(({ id, url }) => ({ id, url }));
  for (const candidate of candidates) {
    const url = new URL(candidate.url);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash) {
      throw new TypeError('Download routes must be credential-free HTTPS URLs');
    }
  }
  const direct = candidates.find((item) => item.id === 'direct');
  const controller = new AbortController();
  const forwardAbort = () => controller.abort('aborted');
  const budget = Number.isFinite(budgetMs)
    ? Math.max(0, Math.min(DOWNLOAD_PROBE_BUDGET_MS, budgetMs)) : DOWNLOAD_PROBE_BUDGET_MS;
  signal?.addEventListener('abort', forwardAbort, { once: true });
  if (signal?.aborted) forwardAbort();
  if (budget === 0) controller.abort('timeout');
  const timer = setTimeout(() => controller.abort('timeout'), budget);
  try {
    // Routes run in parallel; same-route rounds never compete with each other.
    const pending = candidates.map(async (candidate) => {
      const first = await probe(candidate, artifactBytes, fetchImpl, now, controller.signal);
      if (first.status !== 'ok') {
        return [first, { status: 'skipped', ttfbMs: 0, durationMs: 0, bytes: 0, bps: 0 }];
      }
      return [first, await probe(candidate, artifactBytes, fetchImpl, now, controller.signal)];
    });
    const samples = await Promise.all(pending);
    const metrics = candidates.map((candidate, index) => {
      const rounds = samples[index];
      const valid = rounds.every((round) => round.status === 'ok');
      return { id: candidate.id, status: valid ? 'ok' : 'failed', rounds,
        minBps: valid ? Math.min(...rounds.map((round) => round.bps)) : 0,
        ttfbMs: valid ? Math.max(...rounds.map((round) => round.ttfbMs)) : 0 };
    });
    const available = metrics.filter((item) => item.status === 'ok').sort((a, b) =>
      b.minBps - a.minBps || a.ttfbMs - b.ttfbMs || (a.id === 'direct' ? -1 : 1));
    const selected = available.length ? candidates.find((item) => item.id === available[0].id) : direct;
    return { url: selected.url, id: selected.id, reason: available.length ? 'fastest-stable' : 'fallback', metrics };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', forwardAbort);
  }
}
