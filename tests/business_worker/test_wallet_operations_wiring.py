from importlib import util
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def worker_main():
    path = Path(__file__).parents[2] / 'services' / 'business-worker' / 'app' / 'main.py'
    spec = util.spec_from_file_location('wallet_operations_worker_main', path)
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def dependencies(monkeypatch, worker_main):
    monitor = MagicMock()
    handler = MagicMock()
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.monitoring', SimpleNamespace(WalletMonitoringService=monitor))
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.incidents', SimpleNamespace(SandboxWalletAlertHandler=handler))
    monkeypatch.setattr(worker_main, 'WalletService', MagicMock())
    monkeypatch.setattr(worker_main, 'WalletMaintenanceTask', MagicMock())
    return monitor, handler


@pytest.mark.parametrize('production', [True, False])
@pytest.mark.parametrize('configured', [True, False])
def test_wallet_builds_callable_tasks_without_production_sandbox_handler(worker_main, dependencies, monkeypatch, production, configured):
    monitor, handler = dependencies
    settings = SimpleNamespace(environment='production' if production else 'development',
        adjustment_admin_threshold='1000', wallet_confirmation_threshold=20, wallet_conversions_enabled=True)
    factory = object()
    provider = object() if configured else None
    monkeypatch.setattr(worker_main, 'create_custody_provider', lambda _: (provider, 'configured' if configured else 'unavailable'))
    maintenance, monitoring, handlers = worker_main.build_wallet_tasks(settings, factory)
    assert callable(maintenance) and callable(monitoring)
    monitoring()
    monitor.return_value.run_once.assert_called_once_with()
    wallet = worker_main.WalletService.return_value if configured else None
    monitor.assert_called_once_with(factory, wallet_service=wallet)
    if configured:
        maintenance()
        worker_main.WalletMaintenanceTask.return_value.run_once.assert_called_once_with()
        assert worker_main.WalletService.call_args.kwargs['conversions_enabled'] is not production
    else:
        assert maintenance() == {'skipped': 'custody-not-configured'}
        worker_main.WalletService.assert_not_called()
    if production:
        assert handlers == {}
        handler.assert_not_called()
    else:
        assert handlers == {'wallet.alert': handler.return_value}
        handler.assert_called_once_with(factory)


def test_main_passes_bare_wallet_callables_and_merges_alert_handler(worker_main, monkeypatch):
    settings = SimpleNamespace(environment='development', red_packet_max_total=100,
        adjustment_admin_threshold='1000', wallet_confirmation_threshold=20, wallet_conversions_enabled=False,
        email_verification_secret=None, password_reset_secret=None, matrix_provision_secret=None,
        avatar_storage_root='unused')
    monkeypatch.setattr(worker_main, 'Settings', lambda: settings)
    for name in ('create_engine', 'create_session_factory', 'OutboxConsumer', 'RedPacketService', 'LedgerService',
                 'ChatTransferService', 'RedPacketExpiryTask', 'ChatTransferExpiryTask', 'MomentsModerationTask',
                 'email_sender_from_environment', 'SynapseMatrixAdminGateway', 'LocalPrivateAvatarReader', 'signal'):
        monkeypatch.setattr(worker_main, name, MagicMock())
    def maintenance():
        return None
    def monitor():
        return None
    alert = object()
    monkeypatch.setattr(worker_main, 'create_custody_provider', lambda _: (None, 'unavailable'))
    monkeypatch.setattr(worker_main, 'build_wallet_tasks', lambda *_: (maintenance, monitor, {'wallet.alert': alert}), raising=False)
    identity = {'identity.email': object()}
    monkeypatch.setattr(worker_main, 'build_identity_handlers', lambda **_: identity)
    worker = MagicMock()
    monkeypatch.setattr(worker_main, 'Worker', worker)
    worker_main.main()
    tasks = worker.call_args.kwargs['maintenance_tasks']
    assert maintenance in tasks and monitor in tasks
    assert all(callable(task) for task in tasks)
    assert worker.call_args.kwargs['handlers'] == {**identity, 'wallet.alert': alert}
    worker.return_value.run_forever.assert_called_once()
    worker_main.create_engine.return_value.dispose.assert_called_once()


def test_same_named_maintenance_tasks_are_scheduled_independently():
    from worker import Worker
    calls = []
    class Task:
        def __init__(self, name):
            self.name = name
        def run_once(self):
            calls.append(self.name)
    worker = Worker(consumer=MagicMock(), handlers={}, worker_id='fixture',
        maintenance_tasks=[Task('wallet').run_once, Task('monitor').run_once])
    worker.run_maintenance_once()
    worker.run_maintenance_once()
    assert calls == ['wallet', 'monitor']


def test_manual_mode_uses_real_runtime_and_observer_without_custody_fallback(worker_main, dependencies, monkeypatch):
    runtime_factory = MagicMock()
    runtime = runtime_factory.return_value
    source = MagicMock()
    scanner = MagicMock()
    coverage = MagicMock()
    manual_monitor = MagicMock()
    maintenance = MagicMock()
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.runtime', SimpleNamespace(create_manual_wallet_runtime=runtime_factory))
    monkeypatch.setitem(sys.modules, 'app.integrations.tron.funding_source', SimpleNamespace(SQLiteFundingSource=source))
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.funding_scan', SimpleNamespace(FundingScanService=scanner))
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.funding_coverage', SimpleNamespace(FundingCoverageService=coverage))
    monkeypatch.setitem(sys.modules, 'app.modules.wallet.manual_reserve_monitor', SimpleNamespace(ManualReserveMonitor=manual_monitor))
    monkeypatch.setitem(sys.modules, 'tasks.manual_wallet', SimpleNamespace(ManualWalletMaintenanceTask=maintenance))
    custody = MagicMock(side_effect=AssertionError('manual mode must not select custody'))
    monkeypatch.setattr(worker_main, 'create_custody_provider', custody)
    settings = SimpleNamespace(wallet_real_mode='manual_tron', environment='test',
        tron_observer_database_path='isolated-observer.sqlite', wallet_official_address=MagicMock(),
        wallet_official_config_version='fixture-v1',
        wallet_funding_baseline_at=object(), wallet_funding_baseline_height=100)
    factory = object()
    task, monitor, handlers = worker_main.build_wallet_tasks(settings, factory)
    assert task == maintenance.return_value.run_once
    assert handlers == {}
    assert callable(monitor)
    assert monitor == manual_monitor.return_value.run_once
    assert maintenance.call_args.kwargs['monitor'] is manual_monitor.return_value
    dependencies[0].assert_not_called()
    assert scanner.call_args.kwargs['receipts'] is runtime.receipts
    assert scanner.call_args.kwargs['coverage'] is coverage.return_value
    assert scanner.call_args.kwargs['defer_credit'] is True
    assert coverage.call_args.kwargs['finality_adapter'] is runtime.finality
    assert maintenance.call_args.kwargs['runtime'] is runtime
    assert source.call_args.args == ('isolated-observer.sqlite',)
    assert manual_monitor.call_args.kwargs['external_delivery_configured'] is False
    custody.assert_not_called()

    from pydantic import SecretStr
    from tasks.wallet_alert_email import WalletAlertEmailHandler
    sender = MagicMock()
    monkeypatch.setattr(worker_main, 'email_sender_from_environment', lambda: sender)
    settings.wallet_alert_recipient = SecretStr('alerts@example.test')
    _, _, handlers = worker_main.build_wallet_tasks(settings, factory)
    assert isinstance(handlers['wallet.alert'], WalletAlertEmailHandler)
    assert handlers['wallet.alert'].recipient == 'alerts@example.test'
    sender.send_wallet_alert.assert_not_called()
    assert manual_monitor.call_args.kwargs['external_delivery_configured'] is True

    from integrations.email_sender import DisabledEmailSender, SmtpConfig, SmtpEmailSender
    monkeypatch.setattr(worker_main, 'email_sender_from_environment', DisabledEmailSender)
    worker_main.build_wallet_tasks(settings, factory)
    assert manual_monitor.call_args.kwargs['external_delivery_configured'] is False
    actual_sender = SmtpEmailSender(SmtpConfig(host='smtp.example.test', port=587,
        from_address='sender@example.test', use_starttls=True))
    monkeypatch.setattr(worker_main, 'email_sender_from_environment', lambda: actual_sender)
    worker_main.build_wallet_tasks(settings, factory)
    assert manual_monitor.call_args.kwargs['external_delivery_configured'] is True
    settings.wallet_real_funds_enabled = True
    worker_main.build_wallet_tasks(settings, factory)
    assert manual_monitor.call_args.kwargs['external_delivery_configured'] is True
    assert set(manual_monitor.call_args.kwargs) == {'source', 'official_config',
        'activation_baseline_time', 'activation_baseline_height', 'clock', 'external_delivery_configured'}

    settings.wallet_alert_recipient = None
    settings.wallet_real_funds_enabled = True
    with pytest.raises(ValueError, match='alert recipient'):
        worker_main.build_wallet_tasks(settings, factory)
    from integrations.email_sender import DisabledEmailSender
    settings.wallet_alert_recipient = SecretStr('alerts@example.test')
    monkeypatch.setattr(worker_main, 'email_sender_from_environment', DisabledEmailSender)
    runtime.close.reset_mock()
    with pytest.raises(ValueError, match='enabled alert delivery'):
        worker_main.build_wallet_tasks(settings, factory)
    runtime.close.assert_called_once()


def test_manual_mode_requires_observer_path_before_runtime_creation(worker_main, dependencies):
    settings = SimpleNamespace(wallet_real_mode='manual_tron', environment='production', tron_observer_database_path=None)
    with pytest.raises(ValueError, match='observer'):
        worker_main.build_wallet_tasks(settings, object())


@pytest.mark.parametrize('close_fails', [False, True])
def test_startup_failure_closes_wallet_and_engine(worker_main, monkeypatch, close_fails):
    settings = SimpleNamespace(red_packet_max_total=100)
    monkeypatch.setattr(worker_main, 'Settings', lambda: settings)
    for name in ('create_engine', 'create_session_factory', 'OutboxConsumer', 'RedPacketService',
                 'LedgerService', 'ChatTransferService', 'RedPacketExpiryTask', 'ChatTransferExpiryTask'):
        monkeypatch.setattr(worker_main, name, MagicMock())
    class Task:
        close = MagicMock(side_effect=RuntimeError('close failed') if close_fails else None)
        def run_once(self):
            pass
    task = Task()
    monkeypatch.setattr(worker_main, 'build_wallet_tasks', lambda *_: (task.run_once, lambda: None, {}))
    monkeypatch.setattr(worker_main, 'MomentsModerationTask', MagicMock(side_effect=RuntimeError('startup failed')))
    with pytest.raises(RuntimeError):
        worker_main.main()
    task.close.assert_called_once()
    worker_main.create_engine.return_value.dispose.assert_called_once()
