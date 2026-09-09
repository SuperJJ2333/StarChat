import http from 'k6/http';
import {sleep} from 'k6';
import {SharedArray} from 'k6/data';
import exec from 'k6/execution';
import {Counter, Rate, Trend} from 'k6/metrics';
import {parseConfig, makeState, step} from './capacity-core.js';

const accounts = new SharedArray('isolated accounts', () => JSON.parse(
  __ENV.CAPACITY_ACCOUNTS_JSON || open(__ENV.CAPACITY_ACCOUNTS_FILE || '/artifacts/accounts.json')));
const fixtures = new SharedArray('isolated ciphertext fixtures', () => __ENV.CAPACITY_EVENTS_JSON
  ? JSON.parse(__ENV.CAPACITY_EVENTS_JSON)
  : (__ENV.CAPACITY_EVENTS_FILE ? JSON.parse(open(__ENV.CAPACITY_EVENTS_FILE)) : []));
const config = parseConfig(__ENV, Array.from(accounts), Array.from(fixtures));

function duration(value, fallback) {
  const result = value || fallback;
  if (!/^[1-9][0-9]{0,2}[sm]$/.test(result)) throw new Error('Invalid stage duration');
  const seconds = Number(result.slice(0, -1)) * (result.endsWith('m') ? 60 : 1);
  if (seconds > 1800) throw new Error('Each stage must be at most 30 minutes');
  return result;
}

export const options = {
  scenarios: {isolated_matrix: {executor: 'ramping-vus', startVUs: 0,
    stages: [{duration: duration(__ENV.CAPACITY_RAMP, '30s'), target: config.vus},
      {duration: duration(__ENV.CAPACITY_HOLD, '2m'), target: config.vus},
      {duration: duration(__ENV.CAPACITY_RAMP, '30s'), target: 0}], gracefulRampDown: '65s'}},
  maxRedirects: 0,
  // Exclude URL/response body/token-bearing fields from metric output.
  systemTags: ['status', 'method', 'name', 'scenario', 'expected_response'],
  thresholds: {'sync_success': ['rate>0.99'], 'operation_errors': ['count==0'],
    'http_req_duration{name:encrypted_transport_send}': ['p(95)<3000'],
    'http_req_duration{name:membership_join}': ['p(95)<5000'],
    'transport_delivery_errors': ['count==0']},
};

const metrics = {};
for (const name of ['sync_initial_duration', 'sync_incremental_duration']) metrics[name] = new Trend(name, true);
for (const name of ['sync_success', 'send_success', 'membership_success']) metrics[name] = new Rate(name);
for (const name of ['operation_errors', 'transport_events_sent', 'transport_events_received',
  'own_events_observed', 'limited_timelines', 'transport_delivery_errors']) metrics[name] = new Counter(name);
const sink = {add: (name, value = 1) => metrics[name].add(value)};
const state = makeState();

export function setup() {
  const response = http.get(`${config.base}/_capacity/identity`, {redirects:0, tags:{name:'isolation_probe'}});
  let identity;
  try { identity = response.json(); } catch (_) { throw new Error('Isolation probe failed'); }
  if (response.status !== 200 || identity.run_id !== config.runId || identity.server_name !== 'capacity.localhost') throw new Error('Refusing traffic: isolated run identity does not match');
  metrics.operation_errors.add(0);
  metrics.transport_delivery_errors.add(0);
}

export default function () {
  const index = exec.vu.idInTest - 1;
  if (index >= accounts.length) throw new Error('VU has no unique account');
  step(config, accounts[index], state, http, sink, exec.vu.idInTest);
  sleep(0.1); // bound immediate-error/notification loops; normal sync long-polls.
}

export function handleSummary(data) {
  const output = __ENV.CAPACITY_SUMMARY_FILE || '/artifacts/summary.json';
  const sent = data.metrics.transport_events_sent ? data.metrics.transport_events_sent.values.count : 0;
  const observed = data.metrics.own_events_observed ? data.metrics.own_events_observed.values.count : 0;
  const result = {scope:'HTTP transport only; no Megolm decryptions performed',
    run_id:config.runId, load_id:config.loadId, mode:config.mode, target_vus:config.vus,
    sent, own_observed:observed, unobserved_at_end:sent-observed, ...data};
  return {[output]: JSON.stringify(result, null, 2),
    stdout: JSON.stringify({run_id:config.runId, load_id:config.loadId, mode:config.mode, sent, own_observed:observed,
      unobserved_at_end:sent-observed, note:'See artifact summary; this does not prove E2EE correctness.'})+'\n'};
}
