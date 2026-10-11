"""Additional release review: frozen source + local synthetic files only."""
from contextlib import nullcontext
import importlib.util
from pathlib import Path
import os
import subprocess
import sys

import pytest

HERE = Path(__file__).resolve().parent
SUBJECT = Path(os.environ.get('ANDROID_REVIEW_SUBJECT', str(HERE / 'subject')))


@pytest.fixture
def release():
    path = SUBJECT / 'payload/release_2214.py'
    spec = importlib.util.spec_from_file_location('reviewed_android_release', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def static_files(tmp_path, release):
    root, stage, backup = (tmp_path / n for n in ('root', 'stage', 'backup'))
    root.mkdir(); stage.mkdir()
    for name in ('page', 'registry'):
        (root / name).write_bytes(b'old-' + name.encode())
        (stage / name).write_bytes(b'new-' + name.encode())
    (root / 'ios').write_bytes(b'unchanged-ios')
    plan = {'static': {name: {'before': release.sha((root / name).read_bytes()),
                             'after': release.sha((stage / name).read_bytes())}
                       for name in ('page', 'registry')},
            'preserved': {'ios': release.sha(b'unchanged-ios')}}
    return root, stage, backup, plan


def test_apply_failure_never_restores_corrupted_backup(tmp_path, release, monkeypatch):
    root, stage, backup, plan = static_files(tmp_path, release)
    atomic = release.atomic
    def fault(path, data):
        if path.name == 'registry' and data == b'new-registry':
            (backup / 'page').write_bytes(b'CORRUPTED_BACKUP')
            raise OSError('second static write failed')
        atomic(path, data)
    monkeypatch.setattr(release, 'atomic', fault)
    with pytest.raises(OSError):
        release.apply_static(plan, root, stage, backup, lock=lambda _: nullcontext())
    assert (root / 'page').read_bytes() in (b'old-page', b'new-page')
    assert (root / 'ios').read_bytes() == b'unchanged-ios'


def test_apply_failure_preserves_newer_target_drift(tmp_path, release, monkeypatch):
    root, stage, backup, plan = static_files(tmp_path, release)
    atomic = release.atomic
    def fault(path, data):
        if path.name == 'registry' and data == b'new-registry':
            (root / 'page').write_bytes(b'FOREIGN_NEWER_PAGE')
            raise OSError('second static write failed')
        atomic(path, data)
    monkeypatch.setattr(release, 'atomic', fault)
    with pytest.raises(OSError):
        release.apply_static(plan, root, stage, backup, lock=lambda _: nullcontext())
    assert (root / 'page').read_bytes() == b'FOREIGN_NEWER_PAGE'
    assert (root / 'ios').read_bytes() == b'unchanged-ios'


def test_real_host_preservation_rejects_unrelated_container_restart(tmp_path, release, monkeypatch):
    # Alias and Docker are external boundaries; use the actual comparison code.
    import json
    aliases = release.FROZEN_HOST['aliases']
    calls = []
    monkeypatch.setattr(Path, 'is_symlink', lambda _: True)
    monkeypatch.setattr(release.os, 'readlink', lambda path: aliases[path.name])
    rows = [{'Name': '/' + row['name'], 'Id': row['id'], 'Image': row['image'],
             'RestartCount': row['restart_count'], 'State': {'StartedAt': row['started_at']}}
            for row in release.FROZEN_HOST['runtime']]
    unrelated = next(row for row in rows if row['Name'] not in
                     ('/starchat-business-api-1', '/starchat-business-worker-1'))
    unrelated['RestartCount'] += 1
    def docker(args, **kwargs):
        calls.append(args)
        return 'synthetic-id' if args == ['docker', 'ps', '-q'] else json.dumps(rows)
    monkeypatch.setattr(release.subprocess, 'check_output', docker)
    with pytest.raises(ValueError, match='running-container identity drift'):
        release.host_preservation(tmp_path)
    assert all(args[:2] in (['docker', 'ps'], ['docker', 'inspect']) for args in calls)


@pytest.mark.parametrize('content, success', [
    (b'synthetic', True), (b'syntheti', False),
    (b'synthetic-extra', False), (b'SYNTHETIC', False),
])
def test_receiver_exact_bounded_stream(tmp_path, content, success):
    path = SUBJECT / 'execute_release.py'
    spec = importlib.util.spec_from_file_location('reviewed_android_executor', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = tmp_path / 'source'; source.write_bytes(b'synthetic')
    destination = tmp_path / 'received'
    code = module.receive_code(destination.as_posix(), source)
    result = subprocess.run([sys.executable, '-c', code], input=content,
                            capture_output=True, timeout=10)
    assert (result.returncode == 0) is success
    if success:
        assert destination.read_bytes() == b'synthetic'
    # A retry must not overwrite any existing receiver output, even a failed one.
    prior = destination.read_bytes()
    replay = subprocess.run([sys.executable, '-c', code], input=b'synthetic',
                            capture_output=True, timeout=10)
    assert replay.returncode != 0
    assert destination.read_bytes() == prior
