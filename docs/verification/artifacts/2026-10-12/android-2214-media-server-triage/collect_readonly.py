"""One bounded first-party server observation; emit only safe identity/aggregate data."""
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import subprocess
import urllib.error
import urllib.request

TARGETS = ('starchat-gateway-1', 'starchat-synapse-1', 'starchat-synapse-sync-worker-1',
           'starchat-business-api-1', 'starchat-business-worker-1')
LOGS = ('starchat-gateway-1', 'starchat-synapse-1', 'starchat-synapse-sync-worker-1')
ACCESS = re.compile(r'\b([1-5]\d\d)(!)?\s+"(GET|POST|PUT|DELETE|OPTIONS|HEAD|PATCH)\s+(\S+)\s+HTTP/[^\"]+"')


def route(uri):
    path = uri.split('?', 1)[0]
    if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/upload(?:/|$)', path):
        return 'matrix_media_upload'
    if re.match(r'^/_matrix/media/(?:v1|v3|r0)/create(?:/|$)', path):
        return 'matrix_media_create'
    if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/config/?$', path):
        return 'matrix_media_config'
    if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/download(?:/|$)', path):
        return 'matrix_media_download'
    if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/thumbnail(?:/|$)', path):
        return 'matrix_media_thumbnail'
    if path == '/_synapse/client/chatflow/recovery/v1/status':
        return 'recovery_status'
    if path.startswith('/_synapse/client/chatflow/recovery/'):
        return 'recovery_other'
    if re.match(r'^/_matrix/client/(?:v3|r0)/rooms/[^/]+/send(?:/|$)', path):
        return 'matrix_room_send'
    if path.startswith('/api/v1/media/') or path == '/api/v1/media':
        return 'business_media'
    return 'other'


def aggregate(text, gateway):
    counts = Counter()
    timestamps = []
    processed = parsed = unparsed_media = json_rows = 0
    lines = text.splitlines()
    for line in lines:
        prefix, _, body = line.partition(' ')
        if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', prefix):
            timestamps.append(prefix)
        else:
            body = line
        processed += int('Processed request:' in body)
        if gateway:
            try:
                row = json.loads(body)
            except ValueError:
                continue
            if isinstance(row, dict) and isinstance(row.get('request'), dict) and isinstance(row.get('status'), int):
                json_rows += 1
                request = row['request']
                method, uri, status = request.get('method'), request.get('uri'), row['status']
                if method in ('GET', 'POST', 'PUT', 'DELETE', 'OPTIONS', 'HEAD', 'PATCH') and isinstance(uri, str):
                    parsed += 1
                    counts[(route(uri), method, status, False)] += 1
        else:
            match = ACCESS.search(body)
            if match:
                status, disconnected, method, uri = match.groups()
                parsed += 1
                counts[(route(uri), method, int(status), bool(disconnected))] += 1
            elif 'Processed request:' in body and ('/_matrix/media/' in body or '/_matrix/client/v1/media/' in body):
                unparsed_media += 1
    return {'lines': len(lines), 'tail_cap_reached': len(lines) >= 40000,
            'first_available_timestamp': min(timestamps) if timestamps else None,
            'last_available_timestamp': max(timestamps) if timestamps else None,
            'processed_request_marker_lines': processed, 'parsed_requests': parsed,
            'gateway_request_json_rows': json_rows, 'unparsed_media_processed_lines': unparsed_media,
            'request_counts': [{'route': r, 'method': m, 'status': s, 'client_disconnected_marker': d, 'count': n}
                               for (r, m, s, d), n in sorted(counts.items())],
            'scope': 'All clients in bounded retained logs; no account/platform/build attribution and no success-rate claim.'}


def run(args, timeout=12):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('bounded readonly command failed')
    return result.stdout


def main():
    now = datetime.now(timezone.utc)
    since, until = (now-timedelta(hours=2)).isoformat(), now.isoformat()
    report = {'observed_utc': until, 'requested_since_utc': since, 'requested_until_utc': until,
              'log_tail_cap_per_container': 40000, 'operations': {}}

    def observe(name, function):
        try:
            report['operations'][name] = {'read_ok': True, 'result': function()}
        except Exception as error:
            report['operations'][name] = {'read_ok': False, 'error_type': type(error).__name__}

    def health():
        rows = json.loads(run(['docker', 'inspect', *TARGETS]))
        value = []
        for row in rows:
            state = row['State']
            value.append({'name': row['Name'].lstrip('/'), 'id': row['Id'], 'image': row['Image'],
                          'running': state['Running'], 'health': state.get('Health', {}).get('Status'),
                          'restart_count': row['RestartCount'], 'oom_killed': state['OOMKilled'],
                          'started_at': state['StartedAt']})
        return {'services': value, 'running_count': len(run(['docker', 'ps', '-q']).splitlines())}
    observe('live_health_identity', health)

    def media_configuration():
        code = """import json,os,re
from pathlib import Path
p=Path('/data/homeserver.yaml')
allowed={}
for line in p.read_text().splitlines():
 match=re.match(r'^(max_upload_size|enable_media_repo|media_store_path):\\s*(.*?)\\s*(?:#.*)?$',line)
 if match:allowed[match.group(1)]=match.group(2).strip().strip(chr(34)).strip(chr(39))
store=allowed.pop('media_store_path','/data/media_store')
result={'selected_config':allowed,'media_store_exists':Path(store).is_dir()}
if Path(store).is_dir():
 s=os.statvfs(store);result['filesystem_available_bytes']=s.f_bavail*s.f_frsize;result['filesystem_total_bytes']=s.f_blocks*s.f_frsize
print(json.dumps(result))"""
        return json.loads(run(['docker', 'exec', 'starchat-synapse-1', 'python', '-B', '-c', code]))
    observe('synapse_selected_media_config', media_configuration)

    for name in LOGS:
        def log_read(name=name):
            result = subprocess.run(['docker', 'logs', '--timestamps', '--since', since, '--until', until,
                                     '--tail', '40000', name], capture_output=True, text=True, timeout=20)
            if result.returncode:
                raise RuntimeError('bounded log read failed')
            return aggregate(result.stdout+'\n'+result.stderr, name == 'starchat-gateway-1')
        observe(name+'_log_aggregate', log_read)

    for label, path in (('api_readiness', '/api/v1/health/ready'), ('matrix_versions', '/_matrix/client/versions'),
                        ('unauthenticated_media_config', '/_matrix/media/v3/config')):
        def endpoint(path=path, label=label):
            try:
                with urllib.request.urlopen('https://liuhetong888.com'+path, timeout=8) as response:
                    value = {'status': response.status}
                    if label == 'unauthenticated_media_config':
                        data = json.load(response)
                        value['published_upload_size'] = data.get('m.upload.size') if isinstance(data.get('m.upload.size'), int) else None
                    return value
            except urllib.error.HTTPError as error:
                return {'status': error.code, 'note': 'Unauthenticated config may require authorization; no token is used.'}
        observe(label, endpoint)
    report['completed_utc'] = datetime.now(timezone.utc).isoformat()
    report['privacy'] = 'Raw logs only in server process memory; no URI/query/IP/user ID/token/body/attachment/exception text emitted.'
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
