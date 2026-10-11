"""Run installer with real temp files; Docker, flock and POSIX metadata are mocked."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from types import SimpleNamespace

import pytest

SOURCE = Path(__file__).with_name('install_pair_reviewed.py')
SOURCE_SHA256 = '14f26696225e0543c85249a1ee5b48050f496d6e79525d48ddf4cc826996255f'


@pytest.fixture
def install(tmp_path, monkeypatch):
    assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == SOURCE_SHA256
    monkeypatch.setitem(sys.modules, 'fcntl', SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *_: None))
    spec = importlib.util.spec_from_file_location('isolated_install_pair', SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = tmp_path / 'staged'
    module.TARGET = tmp_path / 'ops'
    module.ROOT.mkdir()
    module.TARGET.mkdir()
    names = ['business_refresh_image_probe.py', 'business_release_guard.py']
    before = {name: f"VERSION = 'old-{name}'\n".encode() for name in names}
    after = {name: f"VERSION = 'new-{name}'\n".encode() for name in names}
    module.EXPECTED = {name: (hashlib.sha256(before[name]).hexdigest(),
                              hashlib.sha256(after[name]).hexdigest()) for name in names}
    for name in names:
        (module.ROOT / name).write_bytes(after[name])
        (module.TARGET / name).write_bytes(before[name])
    directory_fd = 123456789
    metadata = []
    module.os = SimpleNamespace(
        O_DIRECTORY=0, open=lambda *_: directory_fd,
        close=lambda fd: None,
        fsync=lambda fd: None if fd == directory_fd else os.fsync(fd),
        chmod=lambda path, mode: metadata.append(('chmod', str(path), mode)),
        chown=lambda path, uid, gid: metadata.append(('chown', str(path), uid, gid)),
        replace=os.replace,
    )
    module.identities = lambda: {'business-api': 'same-api', 'business-worker': 'same-worker'}
    proofs = []
    module.runpy = SimpleNamespace(run_path=lambda _: {'verify_image': lambda image, role:
                                  proofs.append((image, role)) or {'passed': True, 'role': role}})
    # Any unmocked Docker/subprocess invocation is a test failure, not a real call.
    module.subprocess = SimpleNamespace(check_output=lambda *_a, **_kw: pytest.fail('unmocked subprocess'))
    return SimpleNamespace(module=module, names=names, before=before, after=after,
                           metadata=metadata, proofs=proofs, directory_fd=directory_fd)


def receipt(install):
    return json.loads((install.module.ROOT / 'installation.json').read_text())


def test_success_backs_up_and_checks_all_images_without_switch(install):
    m = install.module
    m.main()
    assert install.proofs == [(image, role) for role, image in m.IMAGES]
    assert receipt(install)['stage'] == 'PASS'
    assert receipt(install)['business_containers_unchanged'] is True
    metadata = json.loads((m.ROOT / 'private-guard-before/metadata.json').read_text())
    for name in install.names:
        assert (m.TARGET / name).read_bytes() == install.after[name]
        assert (m.ROOT / 'private-guard-before' / name).read_bytes() == install.before[name]
        assert metadata[name]['sha256'] == m.EXPECTED[name][0]
        original = (m.TARGET / name).stat()
        assert ('chmod', str((m.TARGET / name).with_name(name + '.entry-gate-install.tmp')),
                stat.S_IMODE(original.st_mode)) in install.metadata
        assert any(entry[0] == 'chown' and entry[2:] == (original.st_uid, original.st_gid)
                   for entry in install.metadata)


@pytest.mark.parametrize('which', ['target', 'source'])
def test_wrong_prestate_never_changes_pair(install, which):
    m = install.module
    root = m.TARGET if which == 'target' else m.ROOT
    (root / install.names[1]).write_bytes(b'unexpected')
    snapshot = {name: (m.TARGET / name).read_bytes() for name in install.names}
    with pytest.raises(AssertionError):
        m.main()
    assert {name: (m.TARGET / name).read_bytes() for name in install.names} == snapshot
    assert not (m.ROOT / 'installation.json').exists()


def test_installed_proof_failure_restores_pair(install):
    m = install.module
    m.runpy.run_path = lambda _: (_ for _ in ()).throw(ValueError('proof rejected'))
    with pytest.raises(ValueError):
        m.main()
    assert receipt(install)['restored_old_pair'] is True
    for name in install.names:
        assert (m.TARGET / name).read_bytes() == install.before[name]


def test_replace_success_directory_fsync_failure_is_restored(install):
    m = install.module
    real_fsync = m.os.fsync
    failures = [True]
    def fsync(fd):
        if fd == install.directory_fd and failures:
            failures.pop()
            raise OSError('directory fsync')
        real_fsync(fd)
    m.os.fsync = fsync
    with pytest.raises(OSError):
        m.main()
    assert receipt(install)['restored_old_pair'] is True
    for name in install.names:
        assert (m.TARGET / name).read_bytes() == install.before[name]


def test_second_replace_failure_restores_first(install):
    m = install.module
    real_replace = m.os.replace
    calls = []
    def replace(source, target):
        calls.append(target)
        if len(calls) == 2:
            raise OSError('second replacement')
        real_replace(source, target)
    m.os.replace = replace
    with pytest.raises(OSError):
        m.main()
    assert receipt(install)['restored_old_pair'] is True


def test_external_target_drift_is_not_overwritten(install):
    m = install.module
    drift = b'NEW_EXTERNAL_OWNER'
    def guard_failure(_):
        (m.TARGET / install.names[0]).write_bytes(drift)
        raise ValueError('proof failure')
    m.runpy.run_path = guard_failure
    with pytest.raises(ValueError):
        m.main()
    assert (m.TARGET / install.names[0]).read_bytes() == drift
    assert receipt(install)['manual_inspection_required'] is True


def test_container_identity_drift_fails_and_restores(install):
    m = install.module
    calls = iter([{'worker': 'before'}, {'worker': 'after'}])
    m.identities = lambda: next(calls)
    with pytest.raises(AssertionError):
        m.main()
    assert receipt(install)['restored_old_pair'] is True


@pytest.mark.parametrize('operation', ['fsync', 'chmod', 'chown', 'replace'])
def test_failed_atomic_write_removes_its_temporary_file(install, operation):
    m = install.module
    path = m.TARGET / install.names[0]
    setattr(m.os, operation, lambda *_: (_ for _ in ()).throw(OSError('injected')))
    with pytest.raises(OSError):
        m.atomic_bytes(path, b'new', path.stat())
    assert path.read_bytes() == install.before[path.name]
    assert not path.with_name(path.name + '.entry-gate-install.tmp').exists()


def test_staged_source_drift_never_installs_unverified_bytes(install):
    m = install.module
    def identities():
        (m.ROOT / install.names[0]).write_bytes(b'UNVERIFIED_SOURCE')
        return {'worker': 'same'}
    m.identities = identities
    try:
        m.main()
    except AssertionError:
        pass
    assert (m.TARGET / install.names[0]).read_bytes() in (
        install.before[install.names[0]], install.after[install.names[0]])


def test_corrupted_backup_is_never_written_over_exact_new_bytes(install):
    m = install.module
    def guard_failure(_):
        (m.ROOT / 'private-guard-before' / install.names[0]).write_bytes(b'CORRUPTED_BACKUP')
        raise ValueError('proof failure')
    m.runpy.run_path = guard_failure
    with pytest.raises(ValueError):
        m.main()
    assert (m.TARGET / install.names[0]).read_bytes() in (
        install.before[install.names[0]], install.after[install.names[0]])


def test_existing_foreign_temporary_file_is_preserved(install):
    m = install.module
    path = m.TARGET / install.names[0]
    temporary = path.with_name(path.name + '.entry-gate-install.tmp')
    temporary.write_bytes(b'FOREIGN_ATTEMPT')
    with pytest.raises(FileExistsError):
        m.atomic_bytes(path, b'new', path.stat())
    assert temporary.read_bytes() == b'FOREIGN_ATTEMPT'
    assert path.read_bytes() == install.before[path.name]


@pytest.mark.parametrize('guard_ref, probe_ref', [
    ('8134d959', '7407f374'), ('7407f374', '8134d959'),
])
def test_real_guard_lists_reject_both_mixed_pairs(guard_ref, probe_ref):
    root = next(parent for parent in SOURCE.parents if (parent / '.git').exists())
    def read(ref, filename):
        return subprocess.check_output(['git', 'show', ref + ':scripts/' + filename], cwd=root).decode()
    namespace = {'__name__': 'isolated_guard', '__file__': str(root / 'scripts/business_release_guard.py')}
    exec(compile(read(guard_ref, 'business_release_guard.py'), 'guard', 'exec'), namespace)
    probe = {'__name__': 'isolated_probe'}
    exec(compile(read(probe_ref, 'business_refresh_image_probe.py'), 'probe', 'exec'), probe)
    def run(command, **kwargs):
        if command[:3] == ['docker', 'rm', '-f']:
            return SimpleNamespace(returncode=0)
        return SimpleNamespace(returncode=0, stdout=json.dumps({
            'protocol': 'worker-runtime-refresh-v1', 'role': 'worker', 'passed': True,
            'checks': probe['EXPECTED_CHECKS']['worker']}))
    namespace['subprocess'] = SimpleNamespace(run=run)
    with pytest.raises(ValueError, match='Incomplete'):
        namespace['verify_image']('sha256:' + 'a' * 64, 'worker')
