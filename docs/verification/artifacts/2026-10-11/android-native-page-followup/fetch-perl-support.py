"""Fetch actual missing Perl documentation modules from a fixed official commit."""
import hashlib
import base64
import json
from pathlib import Path
import urllib.request
import time
import sys

ROOT = Path(__file__).resolve().parent
COMMIT = '55dd2f792ffc8cefe614350a411f785374281b24'  # official v5.38.2
manifest = []
total = 0
previous = ROOT / 'perl-support-inputs.json'
if len(sys.argv) > 1 and previous.exists():
    saved = json.loads(previous.read_text(encoding='utf-8'))
    manifest = saved['files']
    total = saved['total_bytes']


def get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'StarChat-native-build-proof'})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            break
        except OSError:
            if attempt == 2:
                raise
            time.sleep(1)
    if len(data) > 2 * 1024 * 1024:
        raise RuntimeError('Input size exceeds expected small build dependency')
    return data


def visit(path, relative=''):
    global total
    url = f'https://api.github.com/repos/Perl/perl5/contents/{path}?ref={COMMIT}'
    entries = json.loads(get(url))
    for item in entries:
        name = '/'.join(filter(None, (relative, item['name'])))
        if item['type'] == 'dir':
            visit(item['path'], name)
        elif item['type'] == 'file' and name.endswith('.pm'):
            raw_url = f'https://raw.githubusercontent.com/Perl/perl5/{COMMIT}/{item["path"]}'
            blob = json.loads(get(item['git_url']))
            if blob['encoding'] != 'base64':
                raise RuntimeError('Unexpected Git blob encoding')
            data = base64.b64decode(blob['content'])
            git_sha = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if git_sha != item['sha']:
                raise RuntimeError('Git blob identity mismatch')
            total += len(data)
            if total > 2 * 1024 * 1024:
                raise RuntimeError('Aggregate dependency size exceeded')
            target = ROOT / 'perl-support' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and target.read_bytes() != data:
                raise RuntimeError('Conflicting module')
            target.write_bytes(data)
            manifest.append({'path': name, 'url': raw_url, 'retrieval_url': item['git_url'], 'git_blob_sha1': git_sha, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})


for package in (sys.argv[1:] or ('Pod-Usage', 'Pod-Simple', 'podlators', 'Pod-Escapes')):
    visit(f'cpan/{package}/lib')
result = {'official_commit': COMMIT, 'perl_release': '5.38.2', 'total_bytes': total, 'files': manifest}
(ROOT / 'perl-support-inputs.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'count': len(manifest), 'bytes': total}))
