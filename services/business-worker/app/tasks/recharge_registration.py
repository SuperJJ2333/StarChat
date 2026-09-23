"""ADR-0077 实施补充：充值案件登记兜底（BOUND 绑定幂等完成，宕机恢复）。"""
from app.modules.recharge.service import RechargeService
from app.modules.wallet.support_payout import expire_support_payout_orders


class RechargeRegistrationTask:
    def __init__(self, session_factory, ledger, *, wallet_runtime=None) -> None:
        self._runtime=wallet_runtime
        self._service = RechargeService(session_factory, ledger=ledger,
            wallet_receipts=getattr(wallet_runtime,'receipts',None),
            official_config=getattr(getattr(wallet_runtime,'receipts',None),'official_config',None))

    def run_batch(self, *, limit: int = 100) -> dict:
        expired = self._service.expire_orders(limit=limit)
        payout_expired = expire_support_payout_orders(self._service.factory,
            now=self._service._utcnow(), limit=limit)
        registration=self._service.sweep_pending_registrations(limit=limit)
        matching=(self._service.reconcile_observed_payments(limit=min(limit,50))
            if self._runtime is not None and self._runtime.deposits_enabled else None)
        return {**registration,
            "expired": expired, "payout_expired": payout_expired,
            **({'matching':matching} if matching is not None else {})}
