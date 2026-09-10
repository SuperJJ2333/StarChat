import logging
from contextlib import ExitStack
import os
from datetime import datetime, timezone
from decimal import Decimal
from signal import SIGINT, SIGTERM, signal
from threading import Event

from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.outbox import OutboxConsumer
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService
from app.modules.transfer.service import ChatTransferService
from app.integrations.custody.factory import create_custody_provider
from app.modules.wallet.service import WalletService
from app.modules.identity.registration import VerificationTokenCodec
from app.modules.identity.recovery import PasswordResetTokenCodec
from app.modules.identity.provisioning import MatrixProvisionTask
from app.modules.identity.matrix_sessions import MatrixSessionService
from app.integrations.matrix_admin import (
    MatrixCredentialCodec,
    SynapseMatrixAdminGateway,
)
from integrations.email_sender import email_sender_from_environment
from integrations.avatar_reader import LocalPrivateAvatarReader
from tasks.identity import IdentityEmailVerificationTask, MatrixProfileSyncTask
from tasks.admin_operation_observation import AdminOperationObservationTask
from tasks.redpacket_expiry import RedPacketExpiryTask
from tasks.chat_transfer_expiry import ChatTransferExpiryTask
from tasks.wallet import WalletMaintenanceTask
from tasks.moments import MomentsModerationTask
from worker import Worker


def build_identity_handlers(
    *,
    session_factory,
    verification_secret: str,
    password_reset_secret: str | None = None,
    public_base_url: str,
    email_sender,
    matrix_gateway=None,
    matrix_provision_secret: str | None = None,
    avatar_reader=None,
) -> dict:
    task = IdentityEmailVerificationTask(
        session_factory,
        token_codec=VerificationTokenCodec(verification_secret.encode("utf-8")),
        password_reset_codec=PasswordResetTokenCodec(password_reset_secret.encode("utf-8")) if password_reset_secret else None,
        public_base_url=public_base_url,
        email_sender=email_sender,
    )
    handlers = {"identity.email": task, "identity.admin_operation": AdminOperationObservationTask()}
    if matrix_gateway is not None:
        handlers['identity.matrix_session'] = MatrixSessionService(
            session_factory, gateway=matrix_gateway).revoke_from_outbox
    if matrix_gateway is not None and matrix_provision_secret is not None:
        handlers["identity.matrix"] = MatrixProvisionTask(
            session_factory,
            gateway=matrix_gateway,
            credential_codec=MatrixCredentialCodec(
                matrix_provision_secret.encode("utf-8")
            ),
        )
    if matrix_gateway is not None and avatar_reader is not None:
        handlers["identity.profile"] = MatrixProfileSyncTask(
            session_factory,
            gateway=matrix_gateway,
            avatar_reader=avatar_reader,
        )
    return handlers


def build_wallet_tasks(settings, session_factory):
    """Independent maintenance/monitor callables and explicit Sandbox delivery."""
    from app.modules.wallet.monitoring import WalletMonitoringService

    if getattr(settings, 'wallet_real_mode', 'disabled') == 'manual_tron':
        from app.core.rate_limits import NoopRateLimiter, RedisRateLimiter
        from app.modules.wallet.runtime import create_manual_wallet_runtime
        from app.integrations.tron.funding_source import SQLiteFundingSource
        from app.modules.wallet.funding_scan import FundingScanService
        from app.modules.wallet.funding_coverage import FundingCoverageService
        from app.modules.wallet.funding import OfficialFundingConfig
        from tasks.manual_wallet import ManualWalletMaintenanceTask
        if not settings.tron_observer_database_path:
            raise ValueError('manual wallet worker requires observer database path')
        recipient = getattr(settings, 'wallet_alert_recipient', None)
        money_enabled = any(getattr(settings, key, False) is True for key in (
            'wallet_real_funds_enabled', 'wallet_deposits_enabled', 'wallet_payout_requests_enabled',
            'wallet_payout_execution_enabled', 'wallet_conversions_enabled'))
        if money_enabled and recipient is None:
            raise ValueError('manual wallet funds require alert recipient')
        from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
        limiter = NoopRateLimiter() if settings.environment == 'test' else RedisRateLimiter.from_url(settings.redis_url)
        runtime = create_manual_wallet_runtime(settings, session_factory, limiter)
        monitor_runner = None
        try:
            def clock():
                return datetime.now(timezone.utc)
            source = SQLiteFundingSource(settings.tron_observer_database_path,
                official_address=settings.wallet_official_address.get_secret_value(), clock=clock,
                solid_head_max_age_seconds=180)
            official = OfficialFundingConfig(settings.wallet_official_address.get_secret_value(),
                settings.wallet_official_config_version)
            coverage = FundingCoverageService(session_factory, finality_adapter=runtime.finality,
                official_config=official, clock=clock)
            scanner = FundingScanService(session_factory, source=source, receipts=runtime.receipts,
                activation_baseline_time=settings.wallet_funding_baseline_at,
                activation_baseline_height=settings.wallet_funding_baseline_height, clock=clock,
                coverage=coverage, defer_credit=True)
            handlers = {}
            external_delivery_configured = False
            if recipient is not None:
                from tasks.wallet_alert_email import WalletAlertEmailHandler
                from integrations.email_sender import DisabledEmailSender
                sender = email_sender_from_environment()
                if money_enabled and isinstance(sender, DisabledEmailSender):
                    raise ValueError('manual wallet funds require enabled alert delivery')
                handlers['wallet.alert'] = WalletAlertEmailHandler(session_factory, email_sender=sender,
                    recipient=recipient.get_secret_value())
                # Configuration only: no SMTP probe or secret reaches heartbeat.
                external_delivery_configured = not isinstance(sender, DisabledEmailSender)
            resample_budget = getattr(settings, 'wallet_manual_stale_resample_budget_seconds', 0)
            resample_options = ({'stale_resample_budget_seconds': resample_budget}
                if hasattr(settings, 'wallet_manual_stale_resample_budget_seconds') else {})
            monitor = ManualReserveMonitor(session_factory, source=source, official_config=official,
                activation_baseline_time=settings.wallet_funding_baseline_at,
                activation_baseline_height=settings.wallet_funding_baseline_height, clock=clock,
                external_delivery_configured=external_delivery_configured, **resample_options)
            monitor.reserve_policy = getattr(settings, 'wallet_reserve_policy', 'full_backing')
            monitor.discovery_sync = lambda: scanner.run_once(funds_enabled=False)
            preparing = getattr(settings, 'wallet_handover_preparation_mode', False)
            secondary_monitor = monitor.preparation_once if preparing else monitor.run_once
            if resample_budget > 0 and not preparing:
                from tasks.reserve_monitor_runner import ReserveMonitorRunner
                monitor_runner = ReserveMonitorRunner(monitor)
                monitor = monitor_runner
                secondary_monitor = monitor_runner.ensure_running
            task = ManualWalletMaintenanceTask(session_factory, runtime=runtime, scanner=scanner, monitor=monitor,
                handover_preparation=preparing, monitor_runner=monitor_runner)
            return task.run_once, secondary_monitor, handlers
        except Exception:
            try:
                if monitor_runner is not None:
                    monitor_runner.close()
            finally:
                runtime.close()
            raise

    # A04：托管 provider 统一工厂注入——生产未接真实托管时资金维护
    # 明确跳过（可观测），绝不静默用沙箱顶替生产资金操作。
    custody_provider, custody_mode = create_custody_provider(settings)
    wallet_service = None
    if custody_provider is None:
        logging.getLogger("business-worker").warning(
            "wallet custody not configured (mode=%s); wallet maintenance skipped", custody_mode
        )
        wallet_maintenance = lambda: {"skipped": "custody-not-configured"}  # noqa: E731
    else:
        wallet_service = WalletService(session_factory, custody_provider, withdrawal_admin_threshold=Decimal(settings.adjustment_admin_threshold), confirmation_threshold=settings.wallet_confirmation_threshold, conversions_enabled=settings.wallet_conversions_enabled and settings.environment != "production")
        wallet_maintenance = WalletMaintenanceTask(session_factory, wallet_service).run_once
    wallet_monitoring = WalletMonitoringService(session_factory, wallet_service=wallet_service).run_once
    alert_handlers = {}
    if settings.environment != 'production':
        from app.modules.wallet.incidents import SandboxWalletAlertHandler
        alert_handlers['wallet.alert'] = SandboxWalletAlertHandler(session_factory)
    return wallet_maintenance, wallet_monitoring, alert_handlers


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    from app.integrations.tron import diagnostics
    diagnostics.configure('business-worker')
    diagnostics.emit('INFO', 'service_started', component='worker')
    settings = Settings()
    engine = create_engine(settings)
    with ExitStack() as resources:
        resources.callback(engine.dispose)
        session_factory = create_session_factory(engine)
        consumer = (OutboxConsumer(session_factory, wallet_handover_preparation_mode=True)
            if getattr(settings, 'wallet_handover_preparation_mode', False) else OutboxConsumer(session_factory))
        redpacket_expiry = RedPacketExpiryTask(session_factory, RedPacketService(session_factory, LedgerService(session_factory), max_total=settings.red_packet_max_total))
        chat_transfer_expiry = ChatTransferExpiryTask(session_factory, ChatTransferService(session_factory, LedgerService(session_factory)))
        wallet_maintenance, wallet_monitoring, alert_handlers = build_wallet_tasks(settings, session_factory)
        wallet_task = getattr(wallet_maintenance, '__self__', None)
        if wallet_task is not None and hasattr(wallet_task, 'close'):
            resources.callback(wallet_task.close)
        moments_moderation = MomentsModerationTask(session_factory)
        email_sender = email_sender_from_environment()
        matrix_gateway = SynapseMatrixAdminGateway(
            homeserver_url=os.getenv("MATRIX_HOMESERVER_URL", "http://synapse:8008"),
            server_name=os.getenv("MATRIX_SERVER_NAME", "matrix.localhost"),
            admin_access_token=os.getenv("SYNAPSE_ADMIN_ACCESS_TOKEN", ""),
        )
        public_base_url = os.getenv("EMAIL_VERIFICATION_PUBLIC_BASE_URL", "http://localhost:8082")
        if settings.environment == "production" and not public_base_url.casefold().startswith("https://"):
            raise ValueError("production email public base URL must use HTTPS")
        identity_handlers = build_identity_handlers(
            session_factory=session_factory,
            verification_secret=(
                settings.email_verification_secret
                or "development-email-verification-secret"
            ),
            password_reset_secret=settings.password_reset_secret,
            public_base_url=public_base_url,
            email_sender=email_sender,
            matrix_gateway=matrix_gateway,
            matrix_provision_secret=(
                settings.matrix_provision_secret
                or "development-matrix-provision-secret"
            ),
            avatar_reader=LocalPrivateAvatarReader(settings.avatar_storage_root),
        )
        stop_event = Event()

        def request_stop(_signum, _frame) -> None:
            stop_event.set()

        signal(SIGTERM, request_stop)
        signal(SIGINT, request_stop)

        worker = Worker(
            consumer=consumer,
            handlers={**identity_handlers, **alert_handlers},
            worker_id=os.getenv("WORKER_ID", "business-worker-1"),
            heartbeat_path=os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/liuhetong-worker-heartbeat"),
            maintenance_tasks=[lambda: redpacket_expiry.run_batch(now=datetime.now(timezone.utc), limit=100), lambda: chat_transfer_expiry.run_batch(now=datetime.now(timezone.utc), limit=100), wallet_maintenance, wallet_monitoring, moments_moderation.run_batch],
        )
        worker.run_forever(
            stop_event=stop_event,
            poll_interval_seconds=float(os.getenv("WORKER_POLL_INTERVAL_SECONDS", "1")),
            limit=int(os.getenv("WORKER_BATCH_SIZE", "50")),
        )


if __name__ == "__main__":
    main()
