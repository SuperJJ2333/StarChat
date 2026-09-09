from types import SimpleNamespace
import pytest

import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location('manual_payout_worker_fixture',
    Path(__file__).resolve().parents[1] / 'business_api/wallet/test_manual_payouts.py')
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
core, request, claim = _fixture.core, _fixture.request, _fixture.claim


def test_disabled_credit_keeps_deferred_chain_observation_running(core):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    calls = []
    runtime = SimpleNamespace(funds_enabled=False, deposits_enabled=False,
        payout_requests_enabled=True, binding=None, payouts=core[0])
    scanner = SimpleNamespace(defer_credit=True,
        run_once=lambda **kwargs: calls.append(kwargs) or {'status': 'OK'})
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime, scanner=scanner)
    result = task.run_once()
    assert calls == [{'funds_enabled': True}]
    assert result['receipts_credited'] == 0


def test_disabled_funds_still_reconciles_durable_payout_without_new_binding(core):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    order = request(core)
    claim(core, order)
    calls = []
    class Binding:
        def activate_pending(self, **kwargs):
            raise AssertionError('disabled funds must not activate bindings')
    class Scan:
        def run_once(self, *, funds_enabled):
            calls.append(funds_enabled)
            return {'status': 'FUNDS_DISABLED'}
    runtime = SimpleNamespace(funds_enabled=False, binding=Binding(), payouts=core[0])
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime, scanner=Scan())
    result = task.run_once()
    assert calls == [False]
    assert result['payouts_checked'] == 1
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'UNKNOWN'
    assert core[5].balance('HOLD:alice') == 10


def test_requested_payout_is_never_claimed_or_cancelled_by_worker(core):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    order = request(core)
    scanner = SimpleNamespace(run_once=lambda **kw: {'status': 'OK'})
    runtime = SimpleNamespace(funds_enabled=True, binding=None, payouts=core[0])
    result = ManualWalletMaintenanceTask(core[1], runtime=runtime, scanner=scanner).run_once()
    assert result['payouts_checked'] == 0
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == 10


def test_pending_binding_is_delegated_and_failure_does_not_stop_scan(core):
    from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    with core[1].begin() as session:
        session.add(WalletAddressOwner(address='isolated-pending-source', user_id='bob', created_at=core[2][0]))
        session.flush()
        session.add(WalletBinding(id='pending-binding', user_id='bob', address='isolated-pending-source',
            version=1, status='PENDING', created_at=core[2][0]))
    calls = []
    class Binding:
        def activate_pending(self, **kwargs):
            calls.append(kwargs)
            raise ValueError('provider details must not escape')
    scanner = SimpleNamespace(run_once=lambda **kw: {'status': 'OK'})
    runtime = SimpleNamespace(funds_enabled=True, binding=Binding(), payouts=core[0])
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime, scanner=scanner)
    result = task.run_once()
    assert calls == [{'user_id': 'bob', 'binding_id': 'pending-binding'}]
    assert result['binding_errors'] == 1
    assert result['scan']['status'] == 'OK'
    assert 'provider details' not in str(result)
    runtime.funds_enabled = False
    task.run_once()
    assert len(calls) == 1


def test_scan_failure_returns_constant_reason(core):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    class Scan:
        def run_once(self, **kwargs):
            raise ValueError('synthetic-sensitive-provider-detail')
    runtime = SimpleNamespace(funds_enabled=False, payouts=core[0])
    result = ManualWalletMaintenanceTask(core[1], runtime=runtime, scanner=Scan()).run_once()
    assert result['scan'] == {'status': 'SCAN_UNAVAILABLE'}
    assert 'synthetic-sensitive' not in str(result)


def test_page_failure_does_not_stop_other_branches(core, monkeypatch):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    runtime = SimpleNamespace(funds_enabled=True, binding=None, payouts=core[0])
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime,
        scanner=SimpleNamespace(run_once=lambda **kw: {'status': 'OK'}))
    def fail(*args):
        raise ValueError('synthetic-sensitive-query-detail')
    monkeypatch.setattr(task, '_page', fail)
    result = task.run_once()
    assert result['binding_errors'] == result['payout_errors'] == 1
    assert result['scan']['status'] == 'OK'


@pytest.mark.parametrize('enabled,scan_status,monitor_status,expected', [
    (True, 'OK', 'PUBLISHED', 1), (True, 'OK', 'UNCHANGED', 1),
    (False, 'FUNDS_DISABLED', 'PUBLISHED', 0), (True, 'SOURCE_UNAVAILABLE', 'PUBLISHED', 0),
    (True, 'OK', 'BLOCKED', 0), (True, 'OK', 'WAITING', 0)])
def test_deferred_credit_requires_enabled_funds_completed_scan_and_published_reserve(
        core, monkeypatch, enabled, scan_status, monitor_status, expected):
    from app.modules.wallet.receipt_models import DepositReceipt
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    calls = []
    def scan(**kwargs):
        calls.append('scan')
        return {'status': scan_status}
    def monitor():
        calls.append('monitor')
        return {'status': monitor_status, 'complete': monitor_status in ('PUBLISHED', 'UNCHANGED')}
    def retry(identifier, *, actor_id):
        assert calls[-1] == 'monitor'
        calls.append('credit')
        return {'status': 'CREDITED'}
    runtime = SimpleNamespace(funds_enabled=enabled, binding=None, payouts=core[0],
        receipts=SimpleNamespace(retry_credit=retry))
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime,
        scanner=SimpleNamespace(run_once=scan), monitor=SimpleNamespace(run_once=monitor))
    monkeypatch.setattr(task, '_page', lambda model, condition, after:
        (['deferred-receipt'] if model is DepositReceipt else [], None))
    result = task.run_once()
    assert calls == ['scan', 'monitor'] + (['credit'] if expected else [])
    assert result['receipts_credited'] == expected


def test_monitor_failure_never_retries_receipts(core, monkeypatch):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    def unavailable():
        raise RuntimeError('private-monitor-error')
    def forbidden(*args, **kwargs):
        raise AssertionError('credit after failed monitor')
    runtime = SimpleNamespace(funds_enabled=True, binding=None, payouts=core[0],
        receipts=SimpleNamespace(retry_credit=forbidden))
    task = ManualWalletMaintenanceTask(core[1], runtime=runtime,
        scanner=SimpleNamespace(run_once=lambda **kw: {'status': 'OK'}),
        monitor=SimpleNamespace(run_once=unavailable))
    result = task.run_once()
    assert result['receipts_credited'] == 0
    assert result['monitor'] == {'status': 'MONITOR_UNAVAILABLE', 'complete': False}
    assert 'private-monitor' not in str(result)


def test_handover_preparation_only_discovers_and_records_preparation_heartbeat(core, monkeypatch):
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    calls = []
    task = ManualWalletMaintenanceTask(core[1], runtime=SimpleNamespace(funds_enabled=False),
        scanner=SimpleNamespace(run_once=lambda **kwargs: calls.append(('scan', kwargs))),
        monitor=SimpleNamespace(preparation_once=lambda: calls.append(('preparation', {}))),
        handover_preparation=True)
    monkeypatch.setattr(task, '_page', lambda *args: pytest.fail('preparation cannot process funds'))
    task.run_once()
    assert calls == [('scan', {'funds_enabled': False}), ('preparation', {})]
    task.runtime.funds_enabled = True
    with pytest.raises(ValueError, match='funds disabled'):
        task.run_once()
