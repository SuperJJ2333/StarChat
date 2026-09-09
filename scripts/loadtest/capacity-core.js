// Pure state machine shared by k6 and executable Node contract tests.
// No network requests occur until parseConfig and the isolation probe pass.
const dockerHosts = ['gateway-worker', 'gateway-baseline', 'synapse', 'synapse-sync-worker'];

function integer(value, fallback, min, max, label) {
  const number = value === undefined || value === '' ? fallback : Number(value);
  if (!Number.isInteger(number) || number < min || number > max) throw new Error(`Invalid ${label}`);
  return number;
}

export function validateOrigin(value, docker = false) {
  const match = /^http:\/\/(localhost|127\.0\.0\.1|\[::1\]|[a-z][a-z0-9-]*)(?::([0-9]{1,5}))?\/?$/.exec(value || '');
  if (!match || (match[2] && (Number(match[2]) < 1 || Number(match[2]) > 65535))) throw new Error('Only isolated HTTP origins are allowed');
  if (!['localhost', '127.0.0.1', '[::1]'].includes(match[1]) && !(docker && dockerHosts.includes(match[1]))) throw new Error('Target is outside the isolated load network');
  return value.replace(/\/$/, '');
}

export function parseConfig(env, accounts, fixtures) {
  if (env.CAPACITY_ISOLATED_TEST !== 'YES') throw new Error('CAPACITY_ISOLATED_TEST=YES is required');
  if (!/^[a-z0-9][a-z0-9-]{3,63}$/.test(env.CAPACITY_RUN_ID || '')) throw new Error('Missing isolated run identifier');
  if (!/^[a-z0-9][a-z0-9-]{3,63}$/.test(env.CAPACITY_LOAD_ID || '')) throw new Error('Missing per-invocation load identifier');
  const base = validateOrigin(env.CAPACITY_BASE_URL, env.CAPACITY_ISOLATED_DOCKER === 'YES');
  const vus = integer(env.CAPACITY_VUS, 2, 1, 500, 'VU count (1–500)');
  const mode = env.CAPACITY_MODE || 'sync';
  if (!['sync', 'transport'].includes(mode)) throw new Error('Mode must be sync or transport');
  if (!Array.isArray(accounts) || accounts.length < vus) throw new Error('Each VU requires a distinct account');
  const users = new Set();
  const tokens = new Set();
  for (const account of accounts) {
    if (!account || typeof account.user_id !== 'string' || !/^@[^\s:]+:capacity\.localhost$/.test(account.user_id) ||
        typeof account.access_token !== 'string' || !account.access_token || /[\s\r\n]/.test(account.access_token) ||
        typeof account.room_id !== 'string' || !/^![^\s]+:capacity\.localhost$/.test(account.room_id)) throw new Error('Invalid isolated account fixture');
    if (account.join_room_id && !/^![^\s]+:capacity\.localhost$/.test(account.join_room_id)) throw new Error('Invalid membership room fixture');
    if (users.has(account.user_id) || tokens.has(account.access_token)) throw new Error('VU identities and access tokens must be unique');
    users.add(account.user_id); tokens.add(account.access_token);
  }
  if (!Array.isArray(fixtures)) throw new Error('Ciphertext fixtures must be a JSON array');
  const events = {};
  for (const fixture of fixtures) {
    const content = fixture && fixture.content;
    const allowed = ['algorithm', 'sender_key', 'device_id', 'session_id', 'ciphertext'];
    if (!content || Object.keys(content).some((key) => !allowed.includes(key)) ||
        allowed.some((key) => typeof content[key] !== 'string' || !content[key]) ||
        content.algorithm !== 'm.megolm.v1.aes-sha2' || !/^[A-Za-z0-9+/=_-]+$/.test(content.ciphertext) ||
        content.ciphertext.length > 1024 * 1024 || !users.has(fixture.user_id)) throw new Error('Only supplied encrypted Matrix event fixtures are accepted');
    const account = accounts.find((item) => item.user_id === fixture.user_id);
    if (fixture.room_id !== account.room_id) throw new Error('Ciphertext fixture belongs to another room');
    if (!events[fixture.user_id]) events[fixture.user_id] = [];
    events[fixture.user_id].push(content);
  }
  if (mode === 'transport' && accounts.slice(0, vus).some((a) => !events[a.user_id])) throw new Error('Transport mode requires ciphertext for every sending VU');
  return {base, vus, mode, runId: env.CAPACITY_RUN_ID, loadId: env.CAPACITY_LOAD_ID, events,
    timeout: integer(env.CAPACITY_SYNC_TIMEOUT_MS, 30000, 1000, 60000, 'sync timeout'),
    sendEvery: integer(env.CAPACITY_SEND_EVERY, 5, 1, 1000, 'send interval')};
}

export function makeState() { return {since: null, joined: false, iteration: 0, pending: {}, sentEventIds: new Set()}; }

function responseJson(response) {
  try { return response.json(); } catch (_) { return null; }
}

function request(config, account, api, method, path, body, name, timeout) {
  return api.request(method, config.base + path, body === null ? null : JSON.stringify(body), {
    headers: {Authorization: `Bearer ${account.access_token}`, 'Content-Type': 'application/json'},
    redirects: 0, timeout: `${timeout || config.timeout + 5000}ms`, tags: {name},
  });
}

export function step(config, account, state, api, metrics, vu) {
  const record = (name, value = 1) => metrics.add(name, value);
  if (!state.joined && account.join_room_id) {
    const joined = request(config, account, api, 'POST', `/_matrix/client/v3/join/${encodeURIComponent(account.join_room_id)}`, {}, 'membership_join', 15000);
    record('membership_success', joined.status === 200);
    if (joined.status !== 200) { record('operation_errors'); return; }
  }
  state.joined = true;
  if (config.mode === 'transport' && state.iteration % config.sendEvery === 0) {
    const fixtures = config.events[account.user_id];
    const content = fixtures[state.iteration % fixtures.length];
    const txid = `${config.loadId}-${vu}-${state.iteration}`;
    const sent = request(config, account, api, 'PUT', `/_matrix/client/v3/rooms/${encodeURIComponent(account.room_id)}/send/m.room.encrypted/${txid}`, content, 'encrypted_transport_send', 15000);
    const response = responseJson(sent);
    record('send_success', sent.status === 200 && !!(response && response.event_id));
    if (sent.status === 200 && response && response.event_id) {
      // A successful send followed by failed /sync retries the same Matrix
      // transaction. Count that accepted event once, not every HTTP response.
      if (!state.sentEventIds.has(response.event_id)) {
        state.sentEventIds.add(response.event_id);
        state.pending[response.event_id] = state.iteration;
        record('transport_events_sent');
      }
    } else record('operation_errors');
  }
  const timeout = state.since ? config.timeout : 0;
  const filter = encodeURIComponent(JSON.stringify({room:{timeline:{limit:100}},presence:{types:[]}}));
  const path = `/_matrix/client/v3/sync?timeout=${timeout}&filter=${filter}` + (state.since ? `&since=${encodeURIComponent(state.since)}` : '');
  const sync = request(config, account, api, 'GET', path, null, state.since ? 'sync_incremental' : 'sync_initial');
  if (sync.timings && typeof sync.timings.duration === 'number') {
    record(state.since ? 'sync_incremental_duration' : 'sync_initial_duration', sync.timings.duration);
  }
  const body = responseJson(sync);
  const valid = sync.status === 200 && body && typeof body.next_batch === 'string' && !!body.next_batch;
  record('sync_success', valid);
  if (!valid) { record('operation_errors'); return; }
  state.since = body.next_batch;
  const room = body.rooms && body.rooms.join && body.rooms.join[account.room_id];
  const timeline = room && room.timeline;
  if (timeline && timeline.limited) record('limited_timelines');
  for (const event of (timeline && timeline.events) || []) {
    if (event.type === 'm.room.encrypted') record('transport_events_received');
    if (Object.prototype.hasOwnProperty.call(state.pending, event.event_id)) {
      delete state.pending[event.event_id]; record('own_events_observed');
    }
  }
  for (const [id, iteration] of Object.entries(state.pending)) {
    if (state.iteration - iteration >= 3) {
      delete state.pending[id]; record('transport_delivery_errors');
    }
  }
  state.iteration++;
}
