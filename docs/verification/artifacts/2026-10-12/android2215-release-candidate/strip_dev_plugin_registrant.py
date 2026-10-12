"""Remove one known dev-only block from this candidate's ignored Java registrant.

Paths are explicit and resolved against --expected-repo. The exact remainder is
kept byte-for-byte. Inspect and verify-clean never write; strip rejects unknown,
missing or repeated blocks instead of widening the correction.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

REGISTRANT_RELATIVE = Path('android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')
BLOCK = (
    b'    try {\n'
    b'      flutterEngine.getPlugins().add(new dev.flutter.plugins.integration_test.IntegrationTestPlugin());\n'
    b'    } catch (Exception e) {\n'
    b'      Log.e(TAG, "Error registering plugin integration_test, dev.flutter.plugins.integration_test.IntegrationTestPlugin", e);\n'
    b'    }\n'
)
DEV_PLUGIN = b'integration_test'


def digest(source: bytes) -> str:
    return hashlib.sha256(source).hexdigest()


def bounded_registrant(mobile_root: Path, expected_repo: Path) -> Path:
    repo = expected_repo.resolve(strict=True)
    if not (repo / '.git').exists():
        raise ValueError('Expected repository has no Git identity')
    mobile = mobile_root.resolve(strict=True)
    expected_mobile = (repo / 'apps/mobile_flutter').resolve(strict=True)
    if mobile != expected_mobile or not mobile.is_relative_to(repo):
        raise ValueError('Mobile root does not belong to the expected repository')
    path = mobile / REGISTRANT_RELATIVE
    resolved = path.resolve(strict=True)
    if resolved != path or not resolved.is_relative_to(mobile) or not resolved.is_file():
        raise ValueError('Registrant is not the exact in-repository generated file')
    return resolved


def remove_known_block(source: bytes) -> bytes:
    candidates = (BLOCK, BLOCK.replace(b'\n', b'\r\n'))
    counts = [source.count(block) for block in candidates]
    if sum(counts) != 1:
        raise ValueError('Expected exactly one byte-exact known dev registration block')
    block = candidates[counts.index(1)]
    start = source.index(block)
    patched = source[:start] + source[start + len(block):]
    if DEV_PLUGIN in patched:
        raise ValueError('Another dev plugin reference remains; refusing to change the file')
    if patched[:start] != source[:start] or patched[start:] != source[start + len(block):]:
        raise ValueError('Production bytes changed outside the known block')
    return patched


def prepare_bytes(source: bytes, mode: str) -> bytes:
    if mode == 'verify-clean':
        if DEV_PLUGIN in source:
            raise ValueError('Dev plugin registration was regenerated')
        return source
    if mode in ('inspect', 'ensure-clean') and DEV_PLUGIN not in source:
        return source
    return remove_known_block(source)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mobile-root', required=True, type=Path)
    parser.add_argument('--expected-repo', required=True, type=Path)
    parser.add_argument('--mode', choices=('inspect', 'strip', 'verify-clean', 'ensure-clean'), required=True)
    parser.add_argument('--expected-sha256')
    args = parser.parse_args()
    path = bounded_registrant(args.mobile_root, args.expected_repo)
    repo = args.expected_repo.resolve(strict=True)
    # Only an ignored generated file is eligible; never patch committed source.
    relative = path.relative_to(repo).as_posix()
    ignored = subprocess.run(['git', '-C', str(repo), 'check-ignore', '--quiet', '--', relative], capture_output=True)
    tracked = subprocess.run(['git', '-C', str(repo), 'ls-files', '--', relative], check=True, capture_output=True)
    if ignored.returncode != 0 or tracked.stdout.strip():
        raise ValueError('Registrant must be ignored and untracked')
    source = path.read_bytes()
    before = digest(source)
    if args.expected_sha256 and before != args.expected_sha256.lower():
        raise ValueError('Registrant SHA256 changed unexpectedly')
    patched = prepare_bytes(source, args.mode)
    will_write = args.mode in ('strip', 'ensure-clean') and patched != source
    if will_write:
        # Recheck resolved target and input immediately before the bounded write.
        if bounded_registrant(args.mobile_root, args.expected_repo) != path:
            raise ValueError('Registrant path changed before correction')
        with path.open('r+b') as stream:
            if stream.read() != source:
                raise ValueError('Registrant bytes changed before correction')
            stream.seek(0)
            stream.write(patched)
            stream.truncate()
        if path.read_bytes() != patched:
            raise ValueError('Corrected registrant readback differs')
    print(json.dumps({'status': 'PASS', 'mode': args.mode, 'registrant': str(path), 'expected_repo': str(repo), 'before_sha256': before, 'after_sha256': digest(patched), 'before_bytes': len(source), 'after_bytes': len(patched), 'changed': will_write, 'outside_block_bytes_preserved': True}, sort_keys=True))


if __name__ == '__main__':
    main()
