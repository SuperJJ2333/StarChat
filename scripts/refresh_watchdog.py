"""Bounded, credential-free refresh monitoring; safe to run once per minute."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from uuid import uuid4

MAX_LOG_BYTES = 4 * 1024 * 1024
MAX_LOG_LINES = 20000


def validate_state(state):
    allowed = {'REFRESH_422','REFRESH_5XX','REFRESH_FAILURE_RATE','PROTOCOL_PROBE_FAILED',
               'MONITOR_CHECK_FAILED','LOG_WINDOW_TRUNCATED','MONITOR_STATE_INVALID'}
    if not isinstance(state,dict) or not isinstance(state.get('active',[]),list) or any(
        not isinstance(v,str) or v not in allowed for v in state.get('active',[])):
        raise ValueError('Invalid state')
    for key in ('last_delivered','checked_at','retry_at','failures'):
        if key in state and (type(state[key]) is not int or state[key] < 0):
            raise ValueError('Invalid state')
    announced = state.get('announced',[])
    sent_at = state.get('sent_at',{})
    if (not isinstance(announced,list) or any(not isinstance(v,str) or v not in allowed for v in announced)
            or not isinstance(sent_at,dict) or any(k not in allowed or type(v) is not int or v < 0 for k,v in sent_at.items())):
        raise ValueError('Invalid state')
    pending = state.get('pending')
    if pending is not None:
        if (not isinstance(pending,dict) or not isinstance(pending.get('id'),str)
                or not re.fullmatch('[a-f0-9-]{36}',pending['id'])
                or pending.get('kind') not in ('alert','recovery')
                or not isinstance(pending.get('reasons'),list)
                or any(not isinstance(v,str) or v not in allowed for v in pending['reasons'])):
            raise ValueError('Invalid state')
    return state


def count_refresh(logs):
    counts = {'total':0, '2xx':0, '401':0, '422':0, '5xx':0, 'other':0}
    for line in logs.splitlines():
        match = re.search(r'POST /api/v1/auth/refresh(\?[^ "\r\n]*)? HTTP/[^"\s]+" (\d{3})', line)
        if not match or match[1] == '?starchat_probe=1':
            continue
        status = int(match[2])
        bucket = '2xx' if 200 <= status < 300 else str(status) if status in (401,422) else '5xx' if 500 <= status < 600 else 'other'
        counts['total'] += 1
        counts[bucket] += 1
    return counts


def reasons(counts, probe_ok):
    result = []
    if counts.get('422',0) >= 3:
        result.append('REFRESH_422')
    if counts.get('5xx',0) >= 3:
        result.append('REFRESH_5XX')
    total = counts.get('total',0)
    if total >= 10 and (total-counts.get('2xx',0))/total >= .2:
        result.append('REFRESH_FAILURE_RATE')
    if not probe_ok:
        result.append('PROTOCOL_PROBE_FAILED')
    return sorted(result)


def transition(previous, active, now):
    state = dict(previous)
    active = sorted(set(active))
    pending = state.get('pending')
    announced = set(state.get('announced', []))
    sent_at = state.get('sent_at', {})
    due = [r for r in active if r not in announced or now-sent_at.get(r,0) >= 300]
    recovered = sorted(announced-set(active))
    # Preserve the one pending event until SMTP accepts it; coalesce only the
    # observed current state. Recovery is generated after its alert is delivered.
    if pending is None and (due or recovered):
        pending = {'id':str(uuid4()), 'kind':'alert' if due else 'recovery', 'reasons':due or recovered,
                   'created_at':now}
        state.update(pending=pending, retry_at=now, failures=0)
    state.update(active=active, checked_at=now)
    event = pending if pending and now >= state.get('retry_at',0) else None
    return state, event


def delivered(state, now):
    announced = set(state.get('announced', []))
    sent_at = dict(state.get('sent_at', {}))
    event = state['pending']
    if event['kind'] == 'alert':
        announced.update(event['reasons'])
        sent_at.update({r:now for r in event['reasons']})
    else:
        announced.difference_update(event['reasons'])
    return {**state, 'announced':sorted(announced), 'sent_at':sent_at, 'pending':None,
            'last_delivered':now, 'failures':0, 'delivery_error':False}


def failed_delivery(state, now):
    failures = state.get('failures',0)+1
    return {**state, 'failures':failures, 'delivery_error':True, 'retry_at':now+min(300,60*2**min(failures-1,3))}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def protocol_probe():
    data = json.dumps({'refresh_token':'starchat-monitor-invalid-not-a-session', 'operation_id':'A'*43}).encode()
    request = urllib.request.Request('https://liuhetong888.com/api/v1/auth/refresh?starchat_probe=1',
        data=data, headers={'Content-Type':'application/json'}, method='POST')
    try:
        urllib.request.build_opener(NoRedirect()).open(request, timeout=10).close()
        return False
    except urllib.error.HTTPError as error:
        body = error.read(4096)
        return error.code == 401 and json.loads(body).get('error',{}).get('code') == 'REFRESH_TOKEN_INVALID'
    except Exception:
        return False


def collect_logs():
    proc = subprocess.Popen(['docker','logs','--since','5m','--tail',str(MAX_LOG_LINES),'starchat-business-api-1'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    timer = threading.Timer(15, proc.kill)
    timer.start()
    try:
        raw = proc.stdout.read(MAX_LOG_BYTES+1)
        truncated = len(raw) > MAX_LOG_BYTES
        if truncated:
            proc.kill()
        code = proc.wait(timeout=5)
        if code and not truncated:
            raise RuntimeError('Log collection failed')
        text = raw[:MAX_LOG_BYTES].decode('utf8', errors='replace')
        truncated |= len(text.splitlines()) >= MAX_LOG_LINES
        return count_refresh(text), truncated
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
        proc.stdout.close()


def send_event(event):
    code = Path(__file__).with_name('refresh_alert_email.py').read_text(encoding='utf8')
    result = subprocess.run(['docker','exec','-i','starchat-business-worker-1','python','-c',code],
        input=json.dumps(event), capture_output=True, text=True, timeout=25)
    if result.returncode or result.stdout.strip() != 'SMTP_ACCEPTED':
        raise RuntimeError('Alert delivery failed')


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, sort_keys=True), encoding='utf8')
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def run_once(folder, failure_only=False):
    import fcntl
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (folder/'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = folder/'state.json'
        invalid_state = False
        try:
            if path.exists() and path.stat().st_size > 16384:
                raise ValueError('Invalid state')
            prior = validate_state(json.loads(path.read_text())) if path.exists() else {}
        except Exception:
            prior, invalid_state = {}, True
        counts = {}
        if failure_only:
            active = prior.get('active', []) if prior.get('pending') else ['MONITOR_CHECK_FAILED']
        else:
            try:
                counts, truncated = collect_logs()
                active = reasons(counts, protocol_probe())
                if truncated:
                    active.append('LOG_WINDOW_TRUNCATED')
            except Exception:
                active = ['MONITOR_CHECK_FAILED']
        if invalid_state:
            active.append('MONITOR_STATE_INVALID')
        now = int(time.time())
        state, event = transition(prior, active, now)
        state['counts'] = counts
        # Persist pending before delivery. A crash may duplicate an email, never silently lose it.
        save(path, state)
        if event:
            try:
                send_event(event)
                state = delivered(state, now)
            except Exception:
                state = failed_delivery(state, now)
            save(path, state)
        print(json.dumps({'active':state['active'], 'counts':counts, 'delivery_error':state.get('delivery_error',False)}))
        return 1 if state.get('delivery_error') else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--state-dir', type=Path, default=Path('/var/lib/starchat-refresh-watch'))
    parser.add_argument('--test-email', action='store_true')
    parser.add_argument('--failure-only', action='store_true')
    args = parser.parse_args()
    if args.test_email:
        try:
            send_event({'id':str(uuid4()), 'kind':'test', 'reasons':['DELIVERY_TEST']})
            print('SMTP_ACCEPTED')
        except Exception:
            print('ALERT_DELIVERY_FAILED')
            raise SystemExit(1)
    else:
        raise SystemExit(run_once(args.state_dir, args.failure_only))
