from datetime import datetime, timezone
from sqlalchemy import select
from app.modules.wallet.models import Withdrawal
from app.modules.wallet.service import WalletService

class WalletMaintenanceTask:
    def __init__(self, session_factory, service: WalletService):
        self.factory = session_factory
        self.service = service

    def run_once(self, *, actor_id: str = "business-worker"):
        resolved = 0
        with self.factory() as session:
            ids = list(session.scalars(select(Withdrawal.id).where(Withdrawal.status == "PROVIDER_SUBMITTED").limit(100)))
        for withdrawal_id in ids:
            try:
                self.service.resolve_unknown_withdrawal(withdrawal_id, actor_id=actor_id)
                resolved += 1
            except ValueError:
                pass
        reconciliation = self.service.reconcile_incremental(actor_id=actor_id)
        return {"resolved": resolved, "reconciliation": reconciliation}
