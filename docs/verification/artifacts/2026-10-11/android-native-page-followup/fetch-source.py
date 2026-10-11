"""Download the authorized fixed OpenSSL release; reject unsafe extraction."""
import hashlib
import json
from pathlib import Path
import tarfile
import urllib.request

root = Path(__file__).resolve().parent
archive = root / 'openssl-1.1.1q.tar.gz'
url = 'https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1q/openssl-1.1.1q.tar.gz'
expected = 'd7939ce614029cdff0b6c20f0e2e5703158a489a72b2507b8bd51bf8c8fd10ca'
if not archive.exists():
    request = urllib.request.Request(url, headers={'User-Agent': 'StarChat-native-build-proof'})
    with urllib.request.urlopen(request, timeout=40) as src, archive.with_suffix('.part').open('wb') as dst:
        total = 0
        while chunk := src.read(65536):
            total += len(chunk)
            if total > 12 * 1024 * 1024:
                raise RuntimeError('Archive exceeds authorized source size')
            dst.write(chunk)
    assert hashlib.sha256(archive.with_suffix('.part').read_bytes()).hexdigest() == expected
    archive.with_suffix('.part').rename(archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
extract = root / 'source'
extract.mkdir(exist_ok=True)
with tarfile.open(archive) as tar:
    for item in tar.getmembers():
        final = (extract / item.name).resolve()
        if not final.is_relative_to(extract) or not (item.isdir() or item.isfile()):
            raise RuntimeError('Unsafe archive entry ' + item.name)
    tar.extractall(extract, filter='data')
print(json.dumps({'url': url, 'sha256': expected, 'bytes': archive.stat().st_size}))
