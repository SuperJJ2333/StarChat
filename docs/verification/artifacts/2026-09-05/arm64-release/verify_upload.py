from pathlib import Path
import hashlib
import json
import shutil
import urllib.request

stage = Path('/opt/starchat/releases/app-0.3.37-arm64')
source = stage/'ChatFlow-0.3.37-arm64.apk'
expected = 'bc52c6d7924e48523fa6686a071b784271bbe8cf503e921b6e6428983132e238'
assert hashlib.sha256(source.read_bytes()).hexdigest() == expected
public = Path('/opt/starchat/frontend/downloads')
target = public/source.name
if target.exists():
    assert hashlib.sha256(target.read_bytes()).hexdigest() == expected
else:
    shutil.copyfile(source, target)
target.chmod(0o644)
digest = hashlib.sha256()
url = 'https://www.liuhetong888.com/downloads/'+source.name
with urllib.request.urlopen(url, timeout=30) as response:
    assert response.status == 200
    for chunk in iter(lambda: response.read(1024*1024), b''):
        digest.update(chunk)
assert digest.hexdigest() == expected
print(json.dumps({'url':url, 'sha256':expected, 'size':source.stat().st_size,
    'old_aliases':{p.name:str(p.readlink()) for p in public.glob('latest-*.apk')}}, indent=2))
