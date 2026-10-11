"""Static ABI/layout evidence only. Does not execute Android libraries."""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent
NDK = Path('C:/Users/Administrator/AppData/Local/Android/Sdk/ndk/28.2.13676358')
BIN = NDK / 'toolchains/llvm/prebuilt/windows-x86_64/bin'
AAR = Path('C:/Users/Administrator/.gradle/caches/modules-2/files-2.1/com.android.ndk.thirdparty/openssl/1.1.1q-beta-1/658128e1c37d6b12a55fb4e8717bb00313177b69/openssl-1.1.1q-beta-1.aar')
EXPECTED_AAR = 'a5b05c4b362d35c022238ef9b2e4e2196248adea3bac9dd683845ee75a3a8d66'
EXPECTED_SOURCE = 'd7939ce614029cdff0b6c20f0e2e5703158a489a72b2507b8bd51bf8c8fd10ca'
REQUIRED = {'PKCS5_PBKDF2_HMAC', 'EVP_sha1', 'EVP_sha256', 'EVP_sha512',
            'EVP_aes_128_ctr', 'EVP_aes_256_ctr', 'EVP_CIPHER_CTX_new',
            'EVP_EncryptInit_ex', 'EVP_EncryptUpdate', 'EVP_EncryptFinal_ex',
            'EVP_CIPHER_CTX_free', 'EVP_Digest'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(tool, *args):
    return subprocess.check_output([str(BIN / tool), *map(str, args)], encoding='utf-8')


def layout(data):
    assert data[:6] == b'\x7fELF\x02\x01'
    phoff = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    headers = []
    for i in range(count):
        kind, flags, offset, vaddr, _, filesz, memsz, align = struct.unpack_from('<IIQQQQQQ', data, phoff + size * i)
        if kind in (1, 0x6474e552):
            headers.append({'type': 'LOAD' if kind == 1 else 'GNU_RELRO', 'flags': flags,
                            'offset': offset, 'vaddr': vaddr, 'filesz': filesz,
                            'memsz': memsz, 'align': align})
    loads = [h for h in headers if h['type'] == 'LOAD']
    relro = [h for h in headers if h['type'] == 'GNU_RELRO']
    return {'headers': headers,
            'all_loads_16k': bool(loads) and all(h['align'] >= 16384 and (h['vaddr'] - h['offset']) % 16384 == 0 for h in loads),
            'relro_present': bool(relro),
            'relro_end_16k': bool(relro) and all((h['vaddr'] + h['memsz']) % 16384 == 0 for h in relro)}


def binary_info(path):
    data = path.read_bytes()
    dynamic = run('llvm-readelf.exe', '-dW', path)
    symbols = sorted(line.split()[0] for line in run('llvm-nm.exe', '-D', '--defined-only', '--format=posix', path).splitlines())
    embedded = {}
    for key in ('compiler', 'OPENSSLDIR', 'ENGINESDIR'):
        matches = re.findall(key.encode() + rb': [^\x00]+', data)
        if matches:
            embedded[key] = matches[0].decode('utf-8')
    return {'sha256': sha(data), 'bytes': len(data), 'layout': layout(data), 'embedded_build_metadata': embedded,
            'soname': re.findall(r'\(SONAME\).*\[(.*?)\]', dynamic),
            'needed': sorted(re.findall(r'\(NEEDED\).*\[(.*?)\]', dynamic)),
            'exported_symbols': symbols}


def macros(abi, include_paths):
    triple = 'aarch64-linux-android21' if abi == 'arm64' else 'x86_64-linux-android21'
    output = run('clang.exe', f'--target={triple}', '-E', '-dM', '-x', 'c',
                 *(arg for path in include_paths for arg in ('-I', path)),
                 '-include', 'openssl/opensslconf.h', 'NUL')
    return dict((parts[1], ' '.join(parts[2:])) for line in output.splitlines()
                if (parts := line.split()) and len(parts) >= 2 and parts[1].startswith('OPENSSL_'))


assert sha(AAR.read_bytes()) == EXPECTED_AAR
archive = ROOT / 'openssl-1.1.1q.tar.gz'
assert sha(archive.read_bytes()) == EXPECTED_SOURCE
with tarfile.open(archive) as tar:
    checked = 0
    for member in tar:
        if member.isfile():
            assert tar.extractfile(member).read() == (ROOT / 'source' / member.name).read_bytes(), member.name
            checked += 1
result = {'source_sha256': EXPECTED_SOURCE, 'source_files_unchanged': checked,
          'baseline_aar_sha256': EXPECTED_AAR, 'abis': {},
          'limits': ['No Android execution', 'No cryptographic known-answer tests',
                     'No app/AAR integration', 'No 16KiB device test',
                     'Historical ndkports q recipe provenance remains unresolved']}
with zipfile.ZipFile(AAR) as aar:
    for abi, prefab in [('arm64', 'arm64-v8a'), ('x86_64', 'x86_64')]:
        baseline = ROOT / f'baseline-{abi}'
        baseline.mkdir(exist_ok=True)
        header_root = baseline / 'include'
        for name in aar.namelist():
            prefix = 'prefab/modules/crypto/include/'
            if name.startswith(prefix) and not name.endswith('/'):
                target = header_root / name.removeprefix(prefix)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(aar.read(name))
        abi_result = {}
        for module in ('crypto', 'ssl'):
            name = f'lib{module}.so'
            old_path = baseline / name
            old_path.write_bytes(aar.read(f'prefab/modules/{module}/libs/android.{prefab}/{name}'))
            new_path = ROOT / f'build-{abi}' / name
            old, new = binary_info(old_path), binary_info(new_path)
            old_symbols, new_symbols = set(old['exported_symbols']), set(new['exported_symbols'])
            normalized = {symbol.split('@')[0] for symbol in new_symbols}
            abi_result[module] = {'baseline': old, 'candidate': new,
                                  'removed_exports': sorted(old_symbols - new_symbols),
                                  'added_exports': sorted(new_symbols - old_symbols),
                                  'soname_equal': old['soname'] == new['soname'],
                                  'needed_equal': old['needed'] == new['needed']}
            if module == 'crypto':
                abi_result[module]['matrix_required_symbols_present'] = REQUIRED <= normalized and bool({'EVP_MD_size', 'EVP_MD_get_size'} & normalized)
            (ROOT / f'{abi}-{module}-readelf.txt').write_text(run('llvm-readelf.exe', '-hW', '-lW', '-dW', new_path), encoding='utf-8')
        old_macros = macros(abi, [header_root])
        new_macros = macros(abi, [ROOT / f'build-{abi}/include', ROOT / 'source/openssl-1.1.1q/include'])
        abi_result['openssl_configuration'] = {'baseline': old_macros, 'candidate': new_macros,
                                               'equal': old_macros == new_macros}
        result['abis'][abi] = abi_result
(ROOT / 'build-static-analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
for abi, item in result['abis'].items():
    print(abi, 'config_equal', item['openssl_configuration']['equal'])
    for module in ('crypto', 'ssl'):
        entry = item[module]
        print(module, 'layout', entry['candidate']['layout']['all_loads_16k'], entry['candidate']['layout']['relro_end_16k'],
              'removed', len(entry['removed_exports']), 'added', len(entry['added_exports']),
              'soname', entry['soname_equal'], 'needed', entry['needed_equal'])
        assert entry['candidate']['layout']['all_loads_16k']
        assert entry['candidate']['layout']['relro_end_16k']
        assert not entry['removed_exports'] and not entry['added_exports']
        assert entry['soname_equal'] and entry['needed_equal']
    assert item['crypto']['matrix_required_symbols_present']
    assert item['openssl_configuration']['equal']
print('STATIC GATE PASS; Android runtime and crypto vector gates NOT RUN')
