from test_manual_operations_api import core, coverage, monitor, operations, threaded_sqlite  # noqa: F401
import pytest


def test_control_api_owner_mfa_snapshot_and_replay(operations, monitor):
    client, headers, _, _ = operations
    path = '/api/v1/admin/wallet/manual/operations/control'
    assert client.get(path).status_code == 401
    status = client.get(path, headers=headers)
    assert status.status_code == 200, status.text
    body = dict(expected_epoch=status.json()['epoch'], snapshot_digest=status.json()['snapshot_digest'],
        reason_code='OWNER_PAUSE', mfa_proof='123456')
    assert client.post(path+'/pause', headers=headers, json=body|{'mfa_proof':'000000'}).status_code == 403
    paused = client.post(path+'/pause', headers=headers, json=body)
    assert paused.status_code == 200, paused.text
    assert paused.json()['withdrawals_paused'] and paused.headers['cache-control'] == 'no-store'
    assert client.post(path+'/pause', headers=headers, json=body).json() == paused.json()
    command = dict(expected_epoch=paused.json()['epoch'], snapshot_digest=paused.json()['snapshot_digest'],
        reason_code='OWNER_RESUME', mfa_proof='123456')
    monitor[0].external_delivery_configured = True
    resumed = client.post(path+'/resume', headers=headers|{'Idempotency-Key':'resume-key'}, json=command)
    assert resumed.status_code == 200, resumed.text
    assert not resumed.json()['withdrawals_paused'] and not resumed.json()['outgoing_restricted']
    assert '123456' not in resumed.text


@pytest.mark.parametrize('revocation', ['role', 'session'])
def test_resume_rechecks_owner_authority_after_chain_read(core, monitor, operations, monkeypatch, revocation):
    from datetime import datetime, timezone
    from sqlalchemy import select
    from app.modules.identity.models import UserRole, RefreshTokenFamily
    client, headers, _, _ = operations
    path = '/api/v1/admin/wallet/manual/operations/control'
    status = client.get(path, headers=headers).json()
    body = dict(expected_epoch=status['epoch'], snapshot_digest=status['snapshot_digest'],
        reason_code='OWNER_PAUSE', mfa_proof='123456')
    paused = client.post(path+'/pause', headers=headers, json=body).json()
    original = monitor[1].read_reserve_cut
    def revoked():
        with core[1].begin() as session:
            if revocation == 'role':
                role = session.get(UserRole, 'ops-role')
                if role is not None:
                    session.delete(role)
            else:
                session.scalar(select(RefreshTokenFamily)).revoked_at = datetime.now(timezone.utc)
        return original()
    monkeypatch.setattr(monitor[1], 'read_reserve_cut', revoked)
    monitor[0].external_delivery_configured = True
    result = client.post(path+'/resume', headers=headers|{'Idempotency-Key':'resume'}, json=dict(
        expected_epoch=paused['epoch'], snapshot_digest=paused['snapshot_digest'], reason_code='OWNER_RESUME', mfa_proof='123456'))
    assert result.status_code in (401, 403), result.text
    from app.modules.wallet.models import WalletControl
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
