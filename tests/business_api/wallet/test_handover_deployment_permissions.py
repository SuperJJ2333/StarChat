"""Exercise production POSIX ownership checks even on Windows test hosts."""
import os
from types import SimpleNamespace

import pytest

from app.core.errors import AppError
from app.modules.wallet import handover_deployment
from test_legacy_handover import handover


def posix_metadata(monkeypatch, *, uid, mode):
    def fstat(descriptor):
        fields = list(os.fstat(descriptor))
        fields[0] = (fields[0] & ~0o777) | mode
        fields[4] = uid
        return os.stat_result(fields)

    monkeypatch.setattr(handover_deployment, 'os', SimpleNamespace(
        name='posix', open=os.open, fdopen=os.fdopen, fstat=fstat,
        O_RDONLY=os.O_RDONLY, O_NOFOLLOW=getattr(os, 'O_NOFOLLOW', 0),
    ))


def load(handover):
    service, _, _, now, _, file = handover
    return handover_deployment.load_deployment(str(file), monitor=service.monitor, now=now[0])


@pytest.mark.parametrize('uid,mode', [(1001, 0o600), (0, 0o644), (0, 0o660)])
def test_untrusted_posix_metadata_is_rejected(handover, monkeypatch, uid, mode):
    posix_metadata(monkeypatch, uid=uid, mode=mode)
    with pytest.raises(AppError) as failure:
        load(handover)
    assert failure.value.code == 'HANDOVER_DEPLOYMENT_EVIDENCE_UNAVAILABLE'
    assert failure.value.status_code == 503


def test_root_private_evidence_still_uses_real_contents(handover, monkeypatch):
    posix_metadata(monkeypatch, uid=0, mode=0o600)
    result = load(handover)
    assert result['record']['manual_source_identity'] == handover[4].source_identity
    handover[5].write_text('{"status":"ready"}', encoding='utf-8')
    with pytest.raises(AppError):
        load(handover)


def test_missing_fixture_evidence_is_not_fabricated(handover):
    handover[5].unlink()
    with pytest.raises(AppError):
        load(handover)


def test_fixture_ownership_adapter_does_not_change_other_files(handover, tmp_path, monkeypatch):
    from deployment_evidence_fixtures import trust_fixture_owner
    posix_metadata(monkeypatch, uid=1001, mode=0o600)
    trust_fixture_owner(monkeypatch, handover[5])
    with handover[5].open('rb') as stream:
        assert handover_deployment.os.fstat(stream.fileno()).st_uid == 0
    other = tmp_path / 'untrusted.json'
    other.write_text('{}', encoding='utf-8')
    with other.open('rb') as stream:
        actual = os.fstat(stream.fileno())
        projected = handover_deployment.os.fstat(stream.fileno())
    assert projected.st_uid == 1001
    assert projected.st_ino == actual.st_ino
