from sqlalchemy import select
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.models import Withdrawal
from app.modules.wallet.service import WalletService

class WalletMaintenanceTask:
    def __init__(self, session_factory, service: WalletService):
        self.factory = session_factory
        self.service = service

    def run_once(self, *, actor_id: str = "business-worker"):
        resolved = 0
        with self.factory() as session:
            ids = list(session.scalars(select(Withdrawal.id).where(Withdrawal.status.in_(
                ["PROVIDER_SUBMITTED", "SUBMITTING", "UNKNOWN"])).limit(100)))
        for withdrawal_id in ids:
            try:
                self.service.resolve_unknown_withdrawal(withdrawal_id, actor_id=actor_id)
                resolved += 1
            except ValueError:
                pass
        orphan = self.service.detect_orphan_external_orders(actor_id=actor_id)
        reconciliation = self.service.reconcile_incremental(actor_id=actor_id)
        signals = []
        for present, code in (
            (orphan['status'] != 'MATCHED', 'ORPHAN_EXTERNAL_ORDER'),
            (not reconciliation.matched, 'RESERVE_DEFICIT'),
        ):
            if present:
                signals.append(dict(fingerprint=f'wallet-maintenance:{code}',
                    code=code, severity='P0', subject_id='global'))
        with self.factory.begin() as session:
            WalletIncidentService(self.factory).observe_in_session(session, signals,
                actor_id=actor_id, complete=True, clear_prefix='wallet-maintenance:')
        return {"resolved": resolved, "reconciliation": reconciliation}
