from datetime import datetime

from sqlalchemy import select

from app.modules.transfer.models import ChatTransfer
from app.modules.transfer.service import ChatTransferService

class ChatTransferExpiryTask:
    def __init__(self, session_factory, service: ChatTransferService) -> None:
        self._session_factory = session_factory
        self._service = service

    def run_batch(self, *, now: datetime, limit: int = 100) -> int:
        with self._session_factory() as session:
            ids = list(session.scalars(select(ChatTransfer.id).where(ChatTransfer.status == "PENDING", ChatTransfer.expires_at <= now).order_by(ChatTransfer.expires_at, ChatTransfer.id).limit(limit)))
        completed = 0
        for transfer_id in ids:
            self._service.expire(transfer_id, now=now, actor_id="business-worker", idempotency_key=f"expire:{transfer_id}")
            completed += 1
        return completed
