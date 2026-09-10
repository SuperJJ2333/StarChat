"""Run INSIDE a new network-none Synapse fixture container; prints no tokens.

Two phases separated by a container restart prove durable generation. Synthetic
credentials stay in that container's isolated /data, never in exported logs.
"""
import hashlib
import hmac
import json
import pathlib
import secrets
import sys
import time
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:8008'
PRIVATE = '/_synapse/client/chatflow/mobile_login'


def request(path, data=None, token=None, timeout=20, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path,
        data=None if data is None else json.dumps(data).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def check(condition, label):
    if not condition:
        raise AssertionError(label)
    print('PASS', label, flush=True)


def register(username, admin=False):
    password = secrets.token_urlsafe(24)
    _, body = request('/_synapse/admin/v1/register')
    nonce = body['nonce']
    mac = hmac.new(b'synthetic-registration-secret',
        '\0'.join([nonce, username, password, 'admin' if admin else 'notadmin']).encode(), hashlib.sha1).hexdigest()
    status, response = request('/_synapse/admin/v1/register', {
        'nonce': nonce, 'username': username, 'password': password, 'admin': admin, 'mac': mac})
    check(status == 200, 'synthetic account registration')
    return password, response['access_token'], response['user_id']


def login(user, password, device, refresh=False):
    status, body = request('/_matrix/client/v3/login', {'type': 'm.login.password',
        'identifier': {'type': 'm.id.user', 'user': user}, 'password': password,
        'device_id': device, 'refresh_token': refresh})
    check(status == 200, 'fixture native login')
    return body


def main():
    import synapse
    check(synapse.__version__ == '1.132.0', 'fixed Synapse 1.132.0')
    for _ in range(100):
        try:
            if request('/_matrix/client/versions')[0] == 200:
                break
        except (OSError, ValueError):
            pass
        time.sleep(.25)
    saved = pathlib.Path('/data/synthetic-probe.json')
    if sys.argv[1] == 'verify':
        state = json.loads(saved.read_text())
        for generation in [1, 2, 3, 4]:
            status, _ = request(PRIVATE, {'user_id': state['user'], 'device_id': 'A', 'generation': generation}, state['admin'])
            check(status == 409, 'successful and failed generations survive process restart')
        check(request('/_matrix/client/v3/account/whoami', token=state['current'])[0] == 200,
              'replay cannot revoke current session')
        return
    _, admin, _ = register('admin', True)
    password, _, user = register('alice')
    _, other, _ = register('bob')
    first = login(user, password, 'A', refresh=True)
    second = login(user, password, 'A')
    third = login(user, password, 'B')
    keys = {'user_id': user, 'device_id': 'A', 'algorithms': ['m.olm.v1.curve25519-aes-sha2'],
            'keys': {'curve25519:A': 'A' * 43, 'ed25519:A': 'B' * 43}}
    check(request('/_matrix/client/v3/keys/upload', {'device_keys': keys}, first['access_token'])[0] == 200,
          'synthetic E2EE public keys uploaded')
    body = {'user_id': user, 'device_id': 'A', 'generation': 1}
    check(request(PRIVATE, body)[0] == 401, 'unauthenticated private request denied')
    check(request(PRIVATE, body, other)[0] == 403, 'non-admin private request denied')
    check(request(PRIVATE, {**body, 'user_id': '@alice:remote.test'}, admin)[0] == 400,
          'remote MXID denied')
    check(request(PRIVATE, {**body, 'user_id': '@admin:diagnostic.example.test'}, admin)[0] == 403,
          'administrator target excluded')
    _, _, locked = register('locked')
    check(request('/_synapse/admin/v2/users/' + locked, {'locked': True}, admin, method='PUT')[0] == 200,
          'fixture account locked')
    check(request(PRIVATE, {**body, 'user_id': locked}, admin)[0] == 403, 'locked account denied')
    check(request(PRIVATE, {**body, 'generation': True}, admin)[0] == 400, 'boolean generation rejected')
    status, result = request(PRIVATE, body, admin)
    check(status == 200 and result.get('device_id') == 'A' and result.get('user_id') == user,
          'private native login succeeds')
    check('refresh_token' not in result, 'new session has no refresh token')
    current = result['access_token']
    for old in [first, second, third]:
        check(request('/_matrix/client/v3/account/whoami', token=old['access_token'])[0] == 401,
              'old device access token invalidated')
    check(request('/_matrix/client/v3/refresh', {'refresh_token': first['refresh_token']})[0] == 401,
          'same-device refresh token invalidated')
    check(request('/_matrix/client/v3/account/whoami', token=other)[0] == 200,
          'unrelated account remains authenticated')
    status, queried = request('/_matrix/client/v3/keys/query', {'device_keys': {user: ['A']}}, current)
    check(status == 200 and queried['device_keys'][user]['A']['keys'] == keys['keys'],
          'current device E2EE identity keys preserved')
    status, devices = request('/_matrix/client/v3/devices', token=current)
    check(status == 200 and [d['device_id'] for d in devices['devices']] == ['A'],
          'exactly one device remains')
    check(request(PRIVATE, body, admin)[0] == 409, 'duplicate generation rejected')
    # A real HTTP caller disconnects while native processing continues. The
    # higher generation must queue behind it, then invalidate its unknown token.
    try:
        request(PRIVATE, {**body, 'generation': 2,
            'initial_device_display_name': 'synthetic-slow'}, admin, timeout=.1)
        raise AssertionError('Expected synthetic upstream timeout')
    except TimeoutError:
        pass
    status, newer = request(PRIVATE, {**body, 'generation': 3, 'device_id': 'B'}, admin)
    check(status == 200, 'new generation completes after disconnected older request')
    current = newer['access_token']
    check(request(PRIVATE, {**body, 'generation': 2}, admin)[0] == 409,
          'late older generation cannot revoke new session')
    # Fault after issuing a real native token must never return access, and
    # compensation must retain the preexisting current device and its token.
    status, failed = request(PRIVATE, {**body, 'generation': 4, 'device_id': 'B',
        'initial_device_display_name': 'synthetic-fail-after-issue'}, admin)
    check(status == 503 and 'access_token' not in failed, 'partial failure returns no access token')
    check(request('/_matrix/client/v3/account/whoami', token=current)[0] == 200,
          'failed-attempt compensation preserves preceding valid token')
    import yaml
    config = yaml.safe_load(pathlib.Path('/data/homeserver.yaml').read_text())['database']
    if config['name'] == 'psycopg2':
        import psycopg2
        db = psycopg2.connect(**config['args'])
        cursor = db.cursor()
        cursor.execute('SELECT COUNT(*) FROM access_tokens WHERE user_id = %s', (user,))
        count = cursor.fetchone()[0]
        cursor.execute("SELECT column_name FROM information_schema.columns WHERE table_name = 'chatflow_mobile_login_generations' ORDER BY ordinal_position")
        columns = [row[0] for row in cursor.fetchall()]
    else:
        import sqlite3
        db = sqlite3.connect('/data/homeserver.db')
        count = db.execute('SELECT COUNT(*) FROM access_tokens WHERE user_id = ?', (user,)).fetchone()[0]
        columns = [row[1] for row in db.execute('PRAGMA table_info(chatflow_mobile_login_generations)')]
    check(count == 1,
          'disconnected and failed attempts leave only current token')
    check(columns == ['user_id', 'generation'],
          'extension table contains no tokens')
    db.close()
    saved.write_text(json.dumps({'admin': admin, 'user': user, 'current': current}))


if __name__ == '__main__':
    main()
