"""ADR-0077 实施补充：充值案件登记兜底（BOUND 绑定幂等完成，宕机恢复）。"""
from app.modules.recharge.service import RechargeService


class RechargeRegistrationTask:
    def __init__(self, session_factory, ledger) -> None:
        self._service = RechargeService(session_factory, ledger=ledger)

    def run_batch(self, *, limit: int = 100) -> dict:
        return self._service.sweep_pending_registrations(limit=limit)
