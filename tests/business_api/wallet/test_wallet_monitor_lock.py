from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import os
import subprocess
import sys
from threading import Event, current_thread, main_thread
from types import SimpleNamespace
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, text
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.models import Withdrawal
from app.modules.wallet.monitoring import WalletMonitoringService


@pytest.fixture(params=['memory', 'sqlite'] + (['postgres'] if os.getenv('REPORTING_PG_URL') else []))
def factories(request, tmp_path):
    admin = None
    if request.param == 'postgres':
        schema = 'monitorlock_' + uuid4().hex
        admin = create_engine(os.environ['REPORTING_PG_URL'])
        with admin.begin() as conn:
            conn.execute(text(f'CREATE SCHEMA {schema}'))
        # A lock connection must not consume the only source connection.
        kwargs = dict(connect_args={'options': f'-csearch_path={schema}'}, pool_size=1, max_overflow=0, pool_timeout=1)
        first = create_engine(os.environ['REPORTING_PG_URL'], **kwargs)
        second = create_engine(os.environ['REPORTING_PG_URL'], **kwargs)
    elif request.param == 'sqlite':
        url = 'sqlite+pysqlite:///' + str(tmp_path / 'monitor.db')
        first, second = create_engine(url), create_engine(url)
    else:
        first = second = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool,
                                       connect_args={'check_same_thread': False})
    Base.metadata.create_all(first)
    yield create_session_factory(first), create_session_factory(second)
    first.dispose()
    if second is not first:
        second.dispose()
    if admin:
        with admin.begin() as conn:
            conn.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


class Wallet:
    def __init__(self, entered=None, release=None):
        self.entered, self.release = entered, release
        self.calls = 0
        self.paused = False

    def reconcile_incremental(self, **kwargs):
        self.calls += 1
        if self.entered:
            self.entered.set()
            assert self.release.wait(10), 'test failed to release stalled scan'
        return SimpleNamespace(matched=True)

    def detect_orphan_external_orders(self, **kwargs):
        return {'status': 'MATCHED'}

    def withdrawals_paused(self):
        return self.paused

    def pause_on_reconciliation_mismatch(self, *args, **kwargs):
        self.paused = True


def test_busy_scan_reads_no_sources_and_cannot_publish_out_of_order_clearance(factories):
    first, second = factories
    entered, release = Event(), Event()
    old_wallet, new_wallet = Wallet(entered, release), Wallet()
    old = WalletMonitoringService(first, wallet_service=old_wallet)
    new = WalletMonitoringService(second, wallet_service=new_wallet)
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(old.run_once)
        try:
            assert entered.wait(5)
            with second.begin() as session:
                at = datetime.now(timezone.utc) - timedelta(minutes=6)
                session.add(Withdrawal(id='new-uncertain', user_id='user', client_order_id='test-order',
                    address='TEST_ONLY', amount=1, status='UNKNOWN', created_at=at, updated_at=at))
            reads = []
            def capture(conn, cursor, statement, parameters, context, executemany):
                if current_thread() is main_thread():
                    reads.append(statement)
            event.listen(second.kw['bind'], 'before_cursor_execute', capture)
            try:
                assert new.run_once() == {'complete': False, 'codes': ['MONITOR_SCAN_BUSY']}
            finally:
                event.remove(second.kw['bind'], 'before_cursor_execute', capture)
            assert new_wallet.calls == 0
            assert reads == []
        finally:
            release.set()
        assert pending.result(timeout=10)['complete'] is True
    assert 'WITHDRAWAL_UNCERTAIN' in new.run_once()['codes']
    incidents = WalletIncidentService(second).list_incidents()['items']
    uncertain = next(row for row in incidents if row['code'] == 'WITHDRAWAL_UNCERTAIN')
    assert uncertain['condition_active'] is True and uncertain['clearance_digest'] is None


def test_scan_lock_is_released_after_unhandled_failure(factories, monkeypatch):
    first, second = factories
    wallet = Wallet()
    def fail():
        raise RuntimeError('injected control read failure')
    monkeypatch.setattr(wallet, 'withdrawals_paused', fail)
    with pytest.raises(RuntimeError, match='injected control read failure'):
        WalletMonitoringService(first, wallet_service=wallet).run_once()
    assert WalletMonitoringService(second, wallet_service=Wallet()).run_once()['complete'] is True


def test_file_and_postgres_locks_coordinate_separate_processes(factories):
    from app.modules.wallet.monitor_lock import monitor_scan_lock
    first, second = factories
    engine = first.kw['bind']
    if engine.url.database == ':memory:':
        pytest.skip('in-memory SQLite is local to one process')
    script = '''
import os
from sqlalchemy import create_engine
from app.core.database import create_session_factory
from app.modules.wallet.monitor_lock import monitor_scan_lock
engine = create_engine(os.environ['WALLET_LOCK_TEST_URL'])
with monitor_scan_lock(create_session_factory(engine)) as acquired:
    print('ACQUIRED' if acquired else 'BUSY')
engine.dispose()
'''
    with monitor_scan_lock(first) as acquired:
        assert acquired
        result = subprocess.run([sys.executable, '-c', script],
                                env={**os.environ, 'WALLET_LOCK_TEST_URL': engine.url.render_as_string(hide_password=False)},
                                capture_output=True, text=True, timeout=15, check=True)
        assert result.stdout.strip() == 'BUSY'
    with monitor_scan_lock(second) as acquired:
        assert acquired
