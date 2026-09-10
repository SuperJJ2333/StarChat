"""Manual-wallet orchestration; all state changes use domain services."""
from sqlalchemy import select
from app.integrations.tron import diagnostics as diag

from app.modules.wallet.binding_models import WalletBinding
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.receipt_models import DepositReceipt


class ManualWalletMaintenanceTask:
    def __init__(self, session_factory, *, runtime, scanner, monitor=None, handover_preparation=False,
                 monitor_runner=None):
        self.factory, self.runtime, self.scanner, self.monitor = session_factory, runtime, scanner, monitor
        self._binding_after = None
        self._payout_after = None
        self._receipt_after = None
        self.handover_preparation = handover_preparation
        self.monitor_runner = monitor_runner

    def close(self):
        try:
            if self.monitor_runner is not None:
                self.monitor_runner.close()
        finally:
            self.runtime.close()

    def _page(self, model, condition, after):
        with self.factory() as session:
            query = select(model.id).where(condition)
            if after is not None:
                query = query.where(model.id > after)
            ids = list(session.scalars(query.order_by(model.id).limit(50)))
            return ids, ids[-1] if len(ids) == 50 else None

    @diag.traced('manual_maintenance')
    def run_once(self):
        enabled = getattr(self.runtime, 'deposits_enabled', self.runtime.funds_enabled)
        if type(enabled) is not bool:
            raise ValueError('explicit funds gate required')
        if self.handover_preparation:
            if enabled or self.monitor is None:
                raise ValueError('handover preparation requires funds disabled and explicit monitor')
            return dict(scan=self.scanner.run_once(funds_enabled=False), monitor=self.monitor.preparation_once())
        result = {'bindings_activated': 0, 'binding_errors': 0,
                  'payouts_checked': 0, 'payout_errors': 0,
                  'receipts_credited': 0, 'receipt_errors': 0}
        if enabled or getattr(self.runtime, 'payout_requests_enabled', False):
            try:
                ids, self._binding_after = self._page(WalletBinding,
                    WalletBinding.status == 'PENDING', self._binding_after)
            except Exception:
                ids = []
                result['binding_errors'] += 1
            for identifier in ids:
                try:
                    with self.factory() as session:
                        user_id = session.scalar(select(WalletBinding.user_id).where(WalletBinding.id == identifier))
                    if user_id is None:
                        continue
                    binding = self.runtime.binding.activate_pending(user_id=user_id, binding_id=identifier)
                    result['bindings_activated'] += int(binding['status'] == 'ACTIVE')
                except Exception:
                    result['binding_errors'] += 1
        # Existing commitments must remain observable and settleable while new
        # funding is disabled. This never claims, signs, cancels or broadcasts.
        try:
            ids, self._payout_after = self._page(ManualPayoutOrder,
                ManualPayoutOrder.status.in_(('CLAIMED', 'UNKNOWN')), self._payout_after)
        except Exception as exc:
            diag.emit('ERROR', 'payout_scan_failed', component='manual_maintenance',
                      reason_code='PAYOUT_SCAN_FAILED', **diag.exception_info(exc))
            ids = []
            result['payout_errors'] += 1
        for identifier in ids:
            try:
                self.runtime.payouts.reconcile(order_id=identifier)
                result['payouts_checked'] += 1
            except Exception:
                result['payout_errors'] += 1
        try:
            # Deferred scanners only register evidence and obligations. Their
            # coverage must continue when the independent credit gate is off.
            observe = enabled or getattr(self.scanner, 'defer_credit', False) is True
            result['scan'] = self.scanner.run_once(funds_enabled=observe)
        except Exception as exc:
            diag.emit('ERROR', 'funding_scan_failed', component='manual_maintenance',
                      reason_code='SCAN_UNAVAILABLE', **diag.exception_info(exc))
            result['scan'] = {'status': 'SCAN_UNAVAILABLE'}
        result['monitor'] = {'status': 'MONITOR_NOT_CONFIGURED', 'complete': False}
        if self.monitor is not None:
            try:
                result['monitor'] = self.monitor.run_once()
            except Exception as exc:
                diag.emit('ERROR', 'monitor_failed', component='manual_maintenance',
                          reason_code='MONITOR_UNAVAILABLE', **diag.exception_info(exc))
                result['monitor'] = {'status': 'MONITOR_UNAVAILABLE', 'complete': False}
        # Observation/obligation registration is not credit. Retry only after
        # this cycle established complete coverage and a usable reserve cut.
        if (enabled and result['scan'].get('status') == 'OK'
                and result['monitor'].get('complete') is True
                and result['monitor'].get('status') in ('PUBLISHED', 'UNCHANGED')):
            try:
                ids, self._receipt_after = self._page(DepositReceipt,
                    (DepositReceipt.status == 'REVIEW') & DepositReceipt.pending_obligation.is_(True)
                    & DepositReceipt.reason_code.in_(('DEFERRED_RESERVE_CHECK', 'RESERVE_UNAVAILABLE')),
                    self._receipt_after)
            except Exception:
                ids = []
                result['receipt_errors'] += 1
            for identifier in ids:
                try:
                    receipt = self.runtime.receipts.retry_credit(identifier, actor_id='wallet-receipt-retry-worker')
                    result['receipts_credited'] += int(receipt['status'] == 'CREDITED')
                except Exception:
                    result['receipt_errors'] += 1
        diag.state('INFO' if result['monitor'].get('complete') else 'WARNING',
                   'maintenance_state', component='manual_maintenance',
                   reason_code=result['monitor'].get('status', 'UNKNOWN'))
        return result
