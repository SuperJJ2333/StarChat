"""After root's publish GO: TLS HEAD and bounded public metadata, no credentials."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
SITE = 'https://www.liuhetong888.com'
NAME = 'ChatFlow-0.4.46-build2215-arm64.apk'
DIRECT = SITE + '/downloads/' + NAME
CDN = 'https://d12fjr06o6tga5.cloudfront.net/downloads/' + NAME
SHA = '4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6'
SIZE = 73262170
CAP = 262144
HEADER_ALLOWLIST = ('content-type', 'content-length', 'cache-control',
                    'access-control-allow-origin', 'access-control-allow-methods',
                    'etag', 'last-modified', 'x-cache')


def request(item, proxy):
    name, url, method = item
    with tempfile.TemporaryDirectory(prefix='http-', dir=HERE) as tmp:
        headers, body = Path(tmp, 'headers'), Path(tmp, 'body')
        cmd = ['curl.exe', '-q', '--silent', '--show-error', '--connect-timeout', '10',
               '--max-time', '25', '--proto', '=https', '--tlsv1.2', '--max-redirs', '0',
               '--proxy', proxy, '--noproxy', '', '--dump-header', str(headers),
               '--output', str(body), '--write-out', '%{json}',
               '--header', 'Cache-Control: no-cache']
        if method == 'HEAD':
            cmd += ['--head', '--header', 'Origin: ' + SITE]
        else:
            if url.endswith('.apk') or '.ipa' in url:
                raise ValueError('Installer GET is forbidden')
            cmd += ['--max-filesize', str(CAP)]
        cmd.append(url)
        started = time.monotonic()
        result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', timeout=35)
        wire = json.loads(result.stdout) if result.stdout.strip() else {}
        selected = {}
        if headers.exists():
            for line in headers.read_text(encoding='iso-8859-1').splitlines():
                key, sep, value = line.partition(':')
                if sep and key.lower() in HEADER_ALLOWLIST:
                    selected[key.lower()] = value.strip()
        data = body.read_bytes() if method == 'GET' and body.exists() else b''
        record = {'name': name, 'url': url, 'method': method, 'curl_exit_code': result.returncode,
                  'http_status': wire.get('http_code'), 'effective_url': wire.get('url_effective'),
                  'ssl_verify_result': wire.get('ssl_verify_result'), 'headers': selected,
                  'download_bytes': wire.get('size_download'),
                  'elapsed_seconds': round(time.monotonic()-started, 3),
                  'curl_error_present': bool(result.stderr.strip())}
        assert len(data) <= CAP, 'Metadata body bound exceeded'
        if name in ('registry', 'download', 'ios_manifest') and result.returncode == 0:
            (HERE / (name + '.body')).write_bytes(data)
            record['body_sha256'] = hashlib.sha256(data).hexdigest()
        return record, data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish-go', required=True, help='Root message or successful publication receipt identity')
    args = parser.parse_args()
    if (HERE / 'public-receipt.json').exists():
        parser.error('Do not overwrite public result; investigate before rerun')
    tunnel = json.loads((HERE / 'tunnel-start.json').read_text(encoding='utf-8'))
    proxy = f"socks5h://127.0.0.1:{tunnel['port']}"
    started = datetime.now(timezone.utc).isoformat()
    api = 'https://liuhetong888.com/api/v1/app-updates/latest'
    items = [('direct_apk', DIRECT, 'HEAD'), ('cdn_apk', CDN, 'HEAD'),
             ('registry', SITE+'/downloads/android-release.json', 'GET'),
             ('download', SITE+'/download', 'GET'),
             ('ios_manifest', SITE+'/downloads/ios/manifest.plist', 'GET'),
             ('android_unauthorized', api+'?platform=android', 'GET'),
             ('ios_unauthorized', api+'?platform=ios', 'GET'),
             ('legacy_unauthorized', api, 'GET')]
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda item: request(item, proxy), items))
    records = {entry['name']: entry for entry, _ in results}
    bodies = {entry['name']: body for entry, body in results}
    checks = {'all_transport_tls_verified': all(r['curl_exit_code'] == 0 and r['ssl_verify_result'] == 0 and r['effective_url'] == r['url'] for r in records.values())}
    for name in ('direct_apk', 'cdn_apk'):
        r = records[name]
        checks[name+'_head_identity'] = r['http_status'] == 200 and r['headers'].get('content-length') == str(SIZE) and r['headers'].get('content-type', '').split(';')[0].strip() in ('application/vnd.android.package-archive', 'application/octet-stream') and r['download_bytes'] == 0
    checks['cdn_cors'] = records['cdn_apk']['headers'].get('access-control-allow-origin') == SITE
    try:
        registry = json.loads(bodies['registry'])
        checks['registry_identity'] = records['registry']['http_status'] == 200 and registry == {'artifact_bytes':SIZE,'build':2215,'cdn_url':CDN,'direct_url':DIRECT,'platform':'android','sha256':SHA,'version':'0.4.46'}
    except (ValueError, TypeError):
        checks['registry_identity'] = False
    checks['registry_mime_no_store'] = 'application/json' in records['registry']['headers'].get('content-type','') and 'no-store' in records['registry']['headers'].get('cache-control','')
    checks['download_page'] = records['download']['http_status'] == 200 and b'0.4.46' in bodies['download'] and b'2215' in bodies['download'] and b'0.4.44' in bodies['download'] and b'2213' in bodies['download']
    try:
        plist = plistlib.loads(bodies['ios_manifest'])['items'][0]
        checks['ios_manifest_unchanged_identity'] = records['ios_manifest']['http_status'] == 200 and plist['metadata']['bundle-version'] == '2213' and plist['metadata']['bundle-identifier'] == 'com.liuhetong.liuhetongMobile' and any(a.get('url') == SITE+'/downloads/ios/ChatFlow-0.4.44-2213-enterprise-9e5d3582.ipa' for a in plist['assets'])
    except (ValueError, KeyError, TypeError, IndexError):
        checks['ios_manifest_unchanged_identity'] = False
    for name in ('android_unauthorized', 'ios_unauthorized', 'legacy_unauthorized'):
        checks[name+'_401'] = records[name]['http_status'] == 401
    receipt = {'status':'WORKSTATION_PUBLIC_LIGHTWEIGHT_PASS' if all(checks.values()) else 'PUBLIC_CHECK_REQUIRES_REVIEW',
               'started_utc':started,'completed_utc':datetime.now(timezone.utc).isoformat(),
               'checker_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'socks_loopback_port':tunnel['port'],'owned_tunnel_pid':tunnel['pid'],
               'root_publish_go':args.publish_go,'expected_sha256':SHA,'expected_bytes':SIZE,
               'checks':checks,'requests':list(records.values()),
               'full_installer_download':False,'production_writes':False,
               'limits':'HEAD checks access and size, not APK bytes/signature. Registry SHA is advertised metadata. Authenticated platform/minima settings require root route/audit receipt; 401 does not reveal them.'}
    (HERE/'public-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps({'status':receipt['status'],'checks':checks},indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
