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
from app.modules.identity.registration import VerificationTokenCodec
from app.modules.identity.recovery import PasswordResetTokenCodec
from app.modules.identity.provisioning import MatrixProvisionTask
from app.integrations.matrix_admin import (
    MatrixCredentialCodec,
    SynapseMatrixAdminGateway,
)
from integrations.email_sender import SmtpConfig, SmtpEmailSender
from integrations.avatar_reader import LocalPrivateAvatarReader
from tasks.identity import IdentityEmailVerificationTask, MatrixProfileSyncTask
from tasks.redpacket_expiry import RedPacketExpiryTask
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
    handlers = {"identity.email": task}
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


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    settings = Settings()
    engine = create_engine(settings)
    session_factory = create_session_factory(engine)
    consumer = OutboxConsumer(session_factory)
    redpacket_expiry = RedPacketExpiryTask(session_factory, RedPacketService(session_factory, LedgerService(session_factory)))
    wallet_service = WalletService(session_factory, SandboxCustodyProvider(secret=settings.wallet_webhook_secret or "development-wallet-webhook-secret"), withdrawal_admin_threshold=Decimal(settings.adjustment_admin_threshold))
    wallet_maintenance = WalletMaintenanceTask(session_factory, wallet_service)
    moments_moderation = MomentsModerationTask(session_factory)
    email_sender = SmtpEmailSender(SmtpConfig.from_environment())
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
        handlers=identity_handlers,
        worker_id=os.getenv("WORKER_ID", "business-worker-1"),
        heartbeat_path=os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/liuhetong-worker-heartbeat"),
        maintenance_tasks=[lambda: redpacket_expiry.run_batch(now=datetime.now(timezone.utc), limit=100), wallet_maintenance.run_once, moments_moderation.run_batch],
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

