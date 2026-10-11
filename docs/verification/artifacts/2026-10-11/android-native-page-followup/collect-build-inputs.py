"""Record the exact local source and tools used by the isolated experiment."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
NDK = Path('C:/Users/Administrator/AppData/Local/Android/Sdk/ndk/28.2.13676358')
BIN = NDK / 'toolchains/llvm/prebuilt/windows-x86_64/bin'
GIT = Path('C:/Program Files/Git/usr/bin')
paths = [NDK / 'source.properties', NDK / 'prebuilt/windows-x86_64/bin/make.exe',
         *(BIN / name for name in ('clang.exe', 'ld.lld.exe', 'llvm-ar.exe', 'llvm-readelf.exe', 'llvm-nm.exe',
                                  'aarch64-linux-android21-clang', 'aarch64-linux-android21-clang.cmd',
                                  'x86_64-linux-android21-clang', 'x86_64-linux-android21-clang.cmd')),
         *(GIT / name for name in ('bash.exe', 'sh.exe', 'perl.exe', 'msys-2.0.dll')),
         Path(sys.executable), ROOT / 'openssl-1.1.1q.tar.gz']
records = []
for path in paths:
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    records.append({'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest})
versions = {}
for path, argument in [(BIN / 'clang.exe', '--version'), (NDK / 'prebuilt/windows-x86_64/bin/make.exe', '--version'),
                       (GIT / 'bash.exe', '--version'), (GIT / 'perl.exe', '-v')]:
    versions[path.name] = subprocess.check_output([str(path), argument], encoding='utf-8')
result = {'host': platform.platform(), 'python': sys.version, 'inputs': records, 'versions': versions,
          'ndk_source_properties': (NDK / 'source.properties').read_text(encoding='utf-8'),
          'official_openssl_archive': 'https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1q/openssl-1.1.1q.tar.gz',
          'tool_installation_mutated': False, 'openssl_source_patched': False,
          'client_gradle_pubcache_production_changed': False}
(ROOT / 'build-tool-inputs.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print('Recorded', len(records), 'hashed inputs')
