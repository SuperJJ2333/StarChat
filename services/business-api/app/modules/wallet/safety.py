"""Application safety operations. External evidence is available only offline."""
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_DOWN, localcontext
import hashlib
from uuid import uuid4

from sqlalchemy import func, select

from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.reserve import RedeemabilityReserve, lock_budget, require_coverage
from app.modules.ledger.service import LedgerService
from app.modules.wallet.models import Deposit, WalletConversion, WalletLedgerEntry, WalletPayoutIntent, WalletSafetyState, Withdrawal
from app.modules.wallet.receipt_models import DepositReceipt


def precise_amount(value, quantum=Decimal('0.000001')):
    try:
        if isinstance(value, float):
            raise ValueError('decimal strings required')
        amount = Decimal(value)
        if not amount.is_finite() or amount <= 0 or amount > Decimal('1000000000') or amount != amount.quantize(quantum):
            raise ValueError('invalid amount or precision')
        return amount.quantize(quantum)
    except (InvalidOperation, TypeError):
        raise ValueError('invalid amount or precision') from None


def audit_write(session, actor, subject, action, reason):
    if not actor or not reason:
        raise ValueError('actor and reason required')
    now = datetime.now(timezone.utc)
    session.add(AuditEvent(id=str(uuid4()), actor_id=actor, subject_type='wallet', subject_id=subject,
        action=action, result='SUCCESS', reason_code=reason,
        trace_id=hashlib.sha256(f'{action}:{subject}'.encode()).hexdigest()[:32], after_data={'action': action}, created_at=now))
    OutboxPublisher.enqueue(session, topic='wallet', event_type=action, aggregate_type='wallet', aggregate_id=subject,
        payload={'id': subject, 'reason_code': reason}, now=now)


def exact_wallet_liability(totals, pending, receipts):
    """Sum database Decimals exactly, including totals beyond Numeric(30,6).

    Aggregate overflow is handled by the reserve boundary, never rounded away.
    Precision includes every operand's integer/fractional places and enough
    carry digits for their count; it does not depend on the global context.
    """
    values = [max(Decimal(value), Decimal('0')) for _, value in totals]
    values.extend((Decimal(pending), Decimal(receipts)))
    if any(not value.is_finite() for value in values):
        raise ValueError('nonfinite wallet liability')
    lowest_exponent = min(-6, *(value.as_tuple().exponent for value in values))
    highest_place = max(0, *(value.adjusted() for value in values))
    with localcontext() as context:
        context.prec = max(40, highest_place - lowest_exponent + len(str(len(values))) + 2)
        return sum(values, Decimal('0.000000'))


def usdt_liability(session):
    totals = session.execute(select(WalletLedgerEntry.account_id, func.sum(WalletLedgerEntry.amount)).where(
        WalletLedgerEntry.account_id.notin_(['PLATFORM_CUSTODY', 'PLATFORM_CONVERSION']), WalletLedgerEntry.asset == 'USDT-TRC20'
    ).group_by(WalletLedgerEntry.account_id)).all()
    pending = session.scalar(select(func.coalesce(func.sum(Deposit.amount), 0)).where(Deposit.status == 'MANUAL_REVIEW'))
    receipts = session.scalar(select(func.coalesce(func.sum(DepositReceipt.amount), 0)).where(DepositReceipt.pending_obligation.is_(True)))
    return exact_wallet_liability(totals, pending, receipts)


class WalletSafetyMixin:
    def _offline_provider(self):
        from app.integrations.custody.sandbox import SandboxCustodyProvider
        if not isinstance(self.provider, SandboxCustodyProvider):
            raise ValueError('real-money custody unavailable')
        return self.provider

    def _check_user(self, session, user_id):
        state = session.get(WalletSafetyState, user_id)
        if state and state.restricted:
            raise ValueError('wallet account restricted')

    def restrict_user(self, user_id, *, actor_id, reason_code):
        if self.conversions_enabled and getattr(self, 'manual_runtime', None) is None:
            self.refresh_reserve_evidence(actor_id=actor_id)
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            state = session.get(WalletSafetyState, user_id, with_for_update=True)
            if state is None:
                state = WalletSafetyState(id=user_id, restricted=True, epoch=1, reason=reason_code)
                session.add(state)
            else:
                state.restricted = True
                state.epoch += 1
                state.reason = reason_code
            audit_write(session, actor_id, user_id, 'wallet.restricted', reason_code)
            if reserve is not None:
                LedgerService(self.factory).restrict_redeemable_outgoing(session=session, actor_id=actor_id, reason_code=reason_code)
                from app.modules.wallet.models import WalletControl
                control = session.get(WalletControl, 'global', with_for_update=True)
                if control is None:
                    session.add(WalletControl(id='global', withdrawals_paused=True, pause_reason='REDEEMABLE_RISK_RESTRICTION'))
                else:
                    control.withdrawals_paused = True
                    control.pause_reason = 'REDEEMABLE_RISK_RESTRICTION'
                audit_write(session, actor_id, 'global', 'wallet.paused', 'REDEEMABLE_RISK_RESTRICTION')

    def refresh_reserve_evidence(self, *, actor_id):
        provider = self._offline_provider()
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            if reserve is None:
                reserve = RedeemabilityReserve(id='global', eligible_usdt=Decimal('0'), usdt_liability=Decimal('0'), version=0, pending_payouts=0, outgoing_restricted=False, observed_at=datetime.now(timezone.utc))
                session.add(reserve)
            reserve.eligible_usdt = Decimal(provider.custody_balance)
            if not reserve.eligible_usdt.is_finite() or reserve.eligible_usdt < 0:
                raise ValueError('invalid external reserve evidence')
            reserve.usdt_liability = usdt_liability(session)
            reserve.pending_payouts = session.scalar(select(func.count()).select_from(Withdrawal).where(Withdrawal.status.in_(['SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN'])))
            # Restrictions recorded before redeemability was enabled must not
            # disappear when a reserve record is first created.
            restricted = session.scalar(select(func.count()).select_from(WalletSafetyState).where(WalletSafetyState.restricted.is_(True)))
            if restricted and not reserve.outgoing_restricted:
                LedgerService(self.factory).restrict_redeemable_outgoing(session=session, actor_id=actor_id, reason_code='EXISTING_RISK_RESTRICTION')
                from app.modules.wallet.models import WalletControl
                control = session.get(WalletControl, 'global', with_for_update=True)
                if control is None:
                    session.add(WalletControl(id='global', withdrawals_paused=True, pause_reason='EXISTING_RISK_RESTRICTION'))
                else:
                    control.withdrawals_paused = True
                    control.pause_reason = 'EXISTING_RISK_RESTRICTION'
            reserve.version += 1
            reserve.observed_at = datetime.now(timezone.utc)
            audit_write(session, actor_id, 'global', 'wallet.reserve_observed', 'SANDBOX_EXTERNAL_EVIDENCE')

    def balances(self, user_id):
        return {'usdt_available': str(self.wallet_ledger.balance(user_id)),
                'usdt_held': str(self.wallet_ledger.balance(f'HOLD:{user_id}')),
                'caibi_available': str(LedgerService(self.factory).balance(user_id)),
                'conversion_enabled': self.conversions_enabled}

    @staticmethod
    def _conversion_result(row):
        source_scale = Decimal('0.01') if row.direction == 'CAIBI_TO_USDT' else Decimal('0.000001')
        target_scale = Decimal('0.000001') if row.direction == 'CAIBI_TO_USDT' else Decimal('0.01')
        return {'id': row.id, 'status': row.status, 'source_amount': str(row.source_amount.quantize(source_scale)),
                'target_amount': str(row.target_amount.quantize(target_scale)), 'direction': row.direction,
                'requested_amount': str(row.requested_amount.quantize(source_scale)), 'remainder': str((row.requested_amount-row.source_amount).quantize(source_scale))}

    def conversion_status(self, conversion_id, user_id):
        with self.factory() as session:
            row = session.get(WalletConversion, conversion_id)
            if row is None or row.user_id != user_id:
                raise ValueError('conversion not found')
            return self._conversion_result(row)

    def convert(self, user_id, direction, amount, idempotency_key):
        if not self.conversions_enabled:
            raise ValueError('conversions disabled')
        manual = getattr(self, 'manual_runtime', None)
        if manual is None:
            self._offline_provider()
        if direction not in {'USDT_TO_CAIBI', 'CAIBI_TO_USDT'} or not idempotency_key or len(idempotency_key) > 128:
            raise ValueError('invalid conversion intent')
        amount = precise_amount(amount, Decimal('0.01') if direction == 'CAIBI_TO_USDT' else Decimal('0.000001'))
        requested_amount = amount
        if direction == 'USDT_TO_CAIBI':
            amount = amount.quantize(Decimal('0.01'), rounding=ROUND_DOWN)
            if amount <= 0:
                raise ValueError('conversion output below 0.01')
        with self.factory() as session:
            existing = session.scalar(select(WalletConversion).where(WalletConversion.user_id == user_id, WalletConversion.idempotency_key == idempotency_key))
            if existing:
                if existing.direction != direction or existing.requested_amount != requested_amount:
                    raise ValueError('conversion idempotency payload conflict')
                return self._conversion_result(existing)
        if manual is None:
            self.refresh_reserve_evidence(actor_id=user_id)
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            self._check_user(session, user_id)
            if manual is not None:
                from app.modules.identity.wallet_access import require_wallet_actor
                require_wallet_actor(session, user_id=user_id, clock=lambda: datetime.now(timezone.utc))
            if self._paused(session):
                raise ValueError('wallet paused')
            existing = session.scalar(select(WalletConversion).where(WalletConversion.user_id == user_id, WalletConversion.idempotency_key == idempotency_key))
            if existing:
                if existing.direction != direction or existing.requested_amount != requested_amount:
                    raise ValueError('conversion idempotency payload conflict')
                return self._conversion_result(existing)
            from app.modules.wallet.conversions import convert_in_session
            row = convert_in_session(session, self.factory, user_id=user_id, direction=direction,
                amount=amount, requested_amount=requested_amount, idempotency_key=idempotency_key,
                reserve_policy=self.reserve_policy)
            return self._conversion_result(row)

    @staticmethod
    def _paused(session):
        from app.modules.wallet.models import WalletControl
        row = session.get(WalletControl, 'global', with_for_update=True)
        return bool(row and row.withdrawals_paused)

    def cancel_withdrawal(self, withdrawal_id, user_id):
        with self.factory.begin() as session:
            lock_budget(session)
            row = session.get(Withdrawal, withdrawal_id, with_for_update=True)
            if row is None or row.user_id != user_id:
                raise ValueError('withdrawal not found')
            if row.status == 'CANCELLED':
                return {'id': row.id, 'status': row.status}
            if row.status not in {'REQUESTED', 'FINANCE_APPROVED', 'ADMIN_APPROVED'} or session.get(WalletPayoutIntent, row.id):
                raise ValueError('withdrawal already submitted or unknown')
            self._release_hold(row, session=session, actor_id=user_id, reason='USER_CANCELLED')
            row.status = 'CANCELLED'
            row.updated_at = datetime.now(timezone.utc)
            audit_write(session, user_id, row.id, 'wallet.cancelled', 'USER_CANCELLED')
            return {'id': row.id, 'status': row.status}

    def snapshot_report(self, actor_id):
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            caibi = LedgerService(self.factory).redeemable_liability(session=session)
            usdt = usdt_liability(session)
            actual = Decimal(self._offline_provider().custody_balance)
            unknown = session.scalars(select(Withdrawal).where(Withdrawal.status.in_(['UNKNOWN', 'SUBMITTING']))).all()
            pending = Decimal(session.scalar(select(func.coalesce(func.sum(Deposit.amount), 0)).where(Deposit.status == 'MANUAL_REVIEW')))
            audit_write(session, actor_id, 'global', 'wallet.report_read', 'REPORT_READ')
            return {'caibi_liability': f'{caibi:.2f}', 'usdt_liability': f'{usdt:.6f}',
                    'eligible_usdt': f'{actual:.6f}', 'required_usdt': f'{caibi + usdt:.6f}',
                    'solvency_surplus': f'{actual-caibi-usdt:.6f}', 'unknown_withdrawal_count': len(unknown),
                    'pending_deposit_payable': f'{pending:.6f}',
                    'reserve_version': reserve.version if reserve else 0, 'withdrawals_paused': self._paused(session),
                    'evidence_kind': 'OFFLINE_SANDBOX', 'cutoff': datetime.now(timezone.utc).isoformat()}

    def detect_orphan_external_orders(self, *, actor_id):
        external = self._offline_provider().enumerate_withdrawals()
        with self.factory() as session:
            orphans = [row['client_order_id'] for row in external if session.get(Withdrawal, row['client_order_id']) is None]
        if orphans:
            self.pause_on_reconciliation_mismatch('ORPHAN_EXTERNAL_ORDER', actor_id=actor_id)
        return {'status': 'ORPHAN_EXTERNAL_ORDER' if orphans else 'MATCHED', 'orphan_order_ids': orphans}
