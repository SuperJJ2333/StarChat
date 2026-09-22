"""ADR-0078：群主抽成兜底结算（幂等；COMPLETED+PENDING 遗漏补结算）。"""
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService


class RedPacketCommissionSweepTask:
    def __init__(self, session_factory) -> None:
        self._service = RedPacketService(session_factory, LedgerService(session_factory))

    def run_batch(self, *, limit: int = 100) -> int:
        return self._service.settle_pending_commissions(limit=limit)
