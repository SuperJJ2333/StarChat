"""Install the reviewed fail-closed guard pair; never switch business containers."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
from datetime import datetime, timezone

ROOT = Path('/opt/starchat/releases/im-worker-entry-guard-20261011-2a6de21d')
TARGET = Path('/opt/starchat/ops/refresh-guards')
EXPECTED = {
    'business_refresh_image_probe.py': ('a2a740124c9a9348e2871e731ea46465b2abf7cb9ea6291771b7a0cfa198658f', '2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15'),
    'business_release_guard.py': ('78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec', '46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b'),
}
IMAGES = (
    ('worker', 'sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a'),
    ('worker', 'sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf'),
    ('api', 'sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3'),
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identities():
    text = subprocess.check_output(['docker', 'ps', '-a', '--no-trunc', '--format', '{{.Names}} {{.ID}}'], text=True, timeout=10)
    return dict(line.split(' ', 1) for line in text.splitlines())


def atomic_bytes(path, data, original):
    temporary = path.with_name(path.name + '.entry-gate-install.tmp')
    owned_identity = None
    try:
        with temporary.open('xb') as stream:
            created = os.fstat(stream.fileno())
            owned_identity = (created.st_dev, created.st_ino)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(original.st_mode))
        os.chown(temporary, original.st_uid, original.st_gid)
        os.replace(temporary, path)
    finally:
        if owned_identity is not None:
            try:
                current = temporary.lstat()
            except FileNotFoundError:
                pass
            else:
                if (current.st_dev, current.st_ino) != owned_identity:
                    raise RuntimeError('temporary ownership changed; refuse removal')
                temporary.unlink()
    descriptor = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main():
    assert ROOT.resolve(strict=True) == ROOT and TARGET.resolve(strict=True) == TARGET
    receipt_path = ROOT / 'installation.json'
    assert not receipt_path.exists(), 'inspect prior attempt; never blind replay'
    lock = (TARGET / '.guard-install.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    states = {}
    source_bytes = {}
    old_bytes = {}
    for name, (old, new) in EXPECTED.items():
        source, target = ROOT / name, TARGET / name
        assert source.is_file() and not source.is_symlink()
        assert target.is_file() and not target.is_symlink()
        source_bytes[name], old_bytes[name] = source.read_bytes(), target.read_bytes()
        assert hashlib.sha256(source_bytes[name]).hexdigest() == new
        assert hashlib.sha256(old_bytes[name]).hexdigest() == old
        compile(source_bytes[name], str(source), 'exec')
        states[name] = target.stat()
    before = identities()
    backup = ROOT / 'private-guard-before'
    backup.mkdir(mode=0o700)
    for name in EXPECTED:
        with (backup / name).open('xb') as stream:
            stream.write(old_bytes[name])
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(backup / name, 0o600)
        assert sha(backup / name) == EXPECTED[name][0], 'backup verification failed'
    (backup / 'metadata.json').write_text(json.dumps({name: {'sha256': EXPECTED[name][0], 'mode': stat.S_IMODE(value.st_mode), 'uid': value.st_uid, 'gid': value.st_gid} for name, value in states.items()}, indent=2))
    os.chmod(backup / 'metadata.json', 0o600)
    receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'stage': 'installing', 'before_sha256': {name: pair[0] for name, pair in EXPECTED.items()}, 'after_sha256': {name: pair[1] for name, pair in EXPECTED.items()}}
    receipt_path.write_text(json.dumps(receipt, indent=2))
    changed = []
    try:
        # During the brief mixed pair, strict proof-list equality rejects both
        # old/new combinations. No intermediate pair can silently bypass checks.
        for name, (old, new) in EXPECTED.items():
            assert sha(TARGET / name) == old
            changed.append(name)  # covers a successful replace followed by fsync failure
            atomic_bytes(TARGET / name, source_bytes[name], states[name])
            assert sha(TARGET / name) == new
        guard = runpy.run_path(str(TARGET / 'business_release_guard.py'))
        receipt['proofs'] = [guard['verify_image'](image, role) for role, image in IMAGES]
        assert before == identities(), 'unrelated container identity drift; inspect'
        assert all(sha(TARGET / name) == pair[1] for name, pair in EXPECTED.items())
        receipt.update(stage='PASS', business_containers_unchanged=True)
    except BaseException as error:
        receipt.update(stage='FAILED', failure_type=type(error).__name__)
        # Restore only this attempt's exact bytes; a concurrent edit is never overwritten.
        try:
            assert all(sha(TARGET / name) in EXPECTED[name] for name in EXPECTED)
            assert all(sha(backup / name) == pair[0] for name, pair in EXPECTED.items()), 'backup integrity changed; refuse recovery'
            for name in reversed(changed):
                if sha(TARGET / name) == EXPECTED[name][1]:
                    atomic_bytes(TARGET / name, old_bytes[name], states[name])
            receipt['restored_old_pair'] = all(sha(TARGET / name) == pair[0] for name, pair in EXPECTED.items())
        except BaseException as recovery_error:
            receipt['recovery_failure_type'] = type(recovery_error).__name__
            receipt['manual_inspection_required'] = True
        raise
    finally:
        receipt['ended_utc'] = datetime.now(timezone.utc).isoformat()
        receipt_path.write_text(json.dumps(receipt, indent=2))
        print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
