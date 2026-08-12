import logging
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
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.service import WalletService
from tasks.redpacket_expiry import RedPacketExpiryTask
from tasks.wallet import WalletMaintenanceTask
from worker import Worker


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    settings = Settings()
    engine = create_engine(settings)
    session_factory = create_session_factory(engine)
    consumer = OutboxConsumer(session_factory)
    redpacket_expiry = RedPacketExpiryTask(session_factory, RedPacketService(session_factory, LedgerService(session_factory)))
    wallet_service = WalletService(session_factory, SandboxCustodyProvider(secret=settings.wallet_webhook_secret or "development-wallet-webhook-secret"), withdrawal_admin_threshold=Decimal(settings.adjustment_admin_threshold))
    wallet_maintenance = WalletMaintenanceTask(session_factory, wallet_service)
    stop_event = Event()

    def request_stop(_signum, _frame) -> None:
        stop_event.set()

    signal(SIGTERM, request_stop)
    signal(SIGINT, request_stop)

    worker = Worker(
        consumer=consumer,
        handlers={},
        worker_id=os.getenv("WORKER_ID", "business-worker-1"),
        heartbeat_path=os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/liuhetong-worker-heartbeat"),
        maintenance_tasks=[lambda: redpacket_expiry.run_batch(now=datetime.now(timezone.utc), limit=100), wallet_maintenance.run_once],
    )
    try:
        worker.run_forever(
            stop_event=stop_event,
            poll_interval_seconds=float(os.getenv("WORKER_POLL_INTERVAL_SECONDS", "1")),
            limit=int(os.getenv("WORKER_BATCH_SIZE", "50")),
        )
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()

