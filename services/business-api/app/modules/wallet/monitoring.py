"""Bounded operational scans. Failed sources cannot clear existing incidents."""
from datetime import datetime, timedelta, timezone

from sqlalchemy import Boolean, DateTime, String, false, func, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.outbox import OutboxEvent
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.models import Withdrawal
from app.modules.wallet.monitor_lock import monitor_scan_lock
from app.modules.wallet.reporting import ReportDataError, WalletReportService
from app.modules.wallet.service import WalletService


class WalletMonitorHeartbeat(Base):
    __tablename__ = 'wallet_monitor_heartbeats'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    last_attempt_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_success_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error_code: Mapped[str | None] = mapped_column(String(100))
    external_delivery_configured: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default=false())


def _aware(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class WalletMonitoringService:
    def __init__(self, factory, *, wallet_service=None, now_factory=None):
        self.factory = factory
        self.wallet = wallet_service
        self.controls = wallet_service or WalletService(factory, None)
        self.now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self.incidents = WalletIncidentService(factory, now_factory=self.now_factory)

    @staticmethod
    def _signal(code, severity='P0', subject='global'):
        return dict(fingerprint=f'{code}:{subject}', code=code, severity=severity, subject_id=subject)

    def run_once(self):
        with monitor_scan_lock(self.factory) as acquired:
            if not acquired:
                return dict(complete=False, codes=['MONITOR_SCAN_BUSY'])
            return self._run_locked_scan()

    def _run_locked_scan(self):
        now = self.now_factory()
        signals = []
        complete = True
        try:
            day = (now + timedelta(hours=8)).date()
            report = WalletReportService(self.factory).daily(day)
            if not report['integrity']['balanced'] or report['integrity']['missing_transaction_metadata']:
                signals.append(self._signal('LEDGER_INTEGRITY'))
            with self.factory() as session:
                uncertain = list(session.scalars(select(Withdrawal.id).where(
                    Withdrawal.status.in_(['UNKNOWN', 'SUBMITTING', 'PROVIDER_SUBMITTED']),
                    Withdrawal.updated_at <= now-timedelta(minutes=5)).limit(1001)))
                if len(uncertain) > 1000:
                    raise OverflowError('monitor evidence cap')
                signals.extend(self._signal('WITHDRAWAL_UNCERTAIN', subject=id) for id in uncertain)
                failed_alerts = session.scalar(select(func.count()).select_from(OutboxEvent).where(
                    OutboxEvent.topic == 'wallet.alert', OutboxEvent.status == 'DEAD'))
                delayed_alerts = session.scalar(select(func.count()).select_from(OutboxEvent).where(
                    OutboxEvent.topic == 'wallet.alert', OutboxEvent.status.in_(['PENDING', 'FAILED', 'PROCESSING']),
                    OutboxEvent.created_at <= now-timedelta(minutes=5)))
            if failed_alerts or delayed_alerts:
                signals.append(self._signal('ALERT_DELIVERY_UNHEALTHY'))
            if self.wallet is None:
                raise RuntimeError('custody unavailable')
            if not self.wallet.reconcile_incremental(actor_id='wallet-monitor').matched:
                signals.append(self._signal('RESERVE_DEFICIT'))
            orphan = self.wallet.detect_orphan_external_orders(actor_id='wallet-monitor')
            if orphan['status'] != 'MATCHED':
                signals.append(self._signal('ORPHAN_EXTERNAL_ORDER'))
        except ReportDataError:
            complete = False
            signals.append(self._signal('LEDGER_INTEGRITY'))
            signals.append(self._signal('MONITOR_UNAVAILABLE', 'P1'))
        except Exception:
            # Never persist provider errors, wallet addresses or other raw exception text.
            complete = False
            signals.append(self._signal('MONITOR_UNAVAILABLE', 'P1'))
        if signals and not self.controls.withdrawals_paused():
            self.controls.pause_on_reconciliation_mismatch('WALLET_MONITOR_SIGNAL', actor_id='wallet-monitor')
        if self.controls.withdrawals_paused():
            signals.append(self._signal('WALLET_PAUSED', 'P1'))
        self.incidents.observe(signals, complete=complete)
        self.incidents.escalate()
        with self.factory.begin() as session:
            row = session.get(WalletMonitorHeartbeat, 'global', with_for_update=True)
            if row is None:
                row = WalletMonitorHeartbeat(id='global', last_attempt_at=now)
                session.add(row)
            row.last_attempt_at = now
            row.external_delivery_configured = False
            row.last_error_code = None if complete else 'MONITOR_UNAVAILABLE'
            if complete:
                row.last_success_at = now
        return dict(complete=complete, codes=sorted({x['code'] for x in signals}))

    def status(self):
        now = self.now_factory()
        with self.factory() as session:
            row = session.get(WalletMonitorHeartbeat, 'global')
            success = _aware(row.last_success_at) if row and row.last_success_at else None
            return dict(last_attempt_at=_aware(row.last_attempt_at).isoformat() if row else None,
                last_success_at=success.isoformat() if success else None,
                last_error_code=row.last_error_code if row else 'MONITOR_NOT_STARTED',
                stale=success is None or not timedelta(0) <= now-success <= timedelta(seconds=120),
                stale_after_seconds=120,
                external_delivery_configured=row.external_delivery_configured if row else False)
