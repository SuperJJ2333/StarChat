from datetime import datetime

from sqlalchemy import select

from app.modules.redpacket.models import RedPacket
from app.modules.redpacket.service import RedPacketService

class RedPacketExpiryTask:
    def __init__(self, session_factory, service: RedPacketService) -> None:
        self._session_factory = session_factory
        self._service = service

    def run_batch(self, *, now: datetime, limit: int = 100) -> int:
        with self._session_factory() as session:
            ids = list(session.scalars(select(RedPacket.id).where(RedPacket.status == "OPEN", RedPacket.expires_at <= now).order_by(RedPacket.expires_at, RedPacket.id).limit(limit)))
        completed = 0
        for packet_id in ids:
            self._service.expire(packet_id, now=now, actor_id="business-worker", idempotency_key=f"expire:{packet_id}")
            completed += 1
        return completed
