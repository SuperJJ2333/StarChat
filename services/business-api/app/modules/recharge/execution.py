"""Recharge-owned gate used by the public approved adjustment workflow."""
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation, localcontext
import hashlib
import secrets
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.recharge.models import RechargeRequest, RechargeCreditBinding
from app.modules.wallet.recharge_receipts import RechargeReceiptOperations, prepare_recharge_credit, complete_recharge_credit, utc
from app.modules.ledger.reserve import lock_budget


def lock_execution_scope(session, *, adjustment_id):
    """Same budget -> order -> adjustment order as receipt bind/verification.

    The budget serializes creation of a new binding while locating its order;
    callers must not acquire an adjustment/binding/receipt lock before this.
    """
    lock_budget(session)
    request_id = session.scalar(select(RechargeCreditBinding.request_id).where(
        RechargeCreditBinding.adjustment_id == adjustment_id).order_by(
            RechargeCreditBinding.created_at.desc()))
    if request_id is not None:
        return session.get(RechargeRequest, request_id, with_for_update=True)
    return None


def require_execution_authorization(row, *, actor_id, claim_token, fresh, now):
    if row is None or row.expires_at is None:
        return
    if not callable(fresh) or not claim_token:
        raise AppError(code='RECHARGE_EXECUTION_AUTHORIZATION_REQUIRED', message='客服结算需要有效的专项授权', status_code=403)
    if (row.claimed_by != actor_id or not row.claim_token_hash
            or not secrets.compare_digest(row.claim_token_hash, hashlib.sha256(claim_token.encode()).hexdigest())
            or row.claim_expires_at is None or utc(row.claim_expires_at) <= now):
        raise AppError(code='RECHARGE_CLAIM_LOST', message='订单认领已失效', status_code=409)


def support_adjustment_terms(session, *, request_id, actor_id, claim_token, final_rate, now):
    """Read-only public order boundary: no client-selected recipient or credit amount."""
    lock_budget(session)
    row = session.get(RechargeRequest, request_id, with_for_update=True)
    token_hash = hashlib.sha256((claim_token or '').encode()).hexdigest()
    if (row is None or row.status != 'SUBMITTED' or row.expires_at is None
            or row.claimed_by != actor_id or not row.claim_token_hash
            or not secrets.compare_digest(row.claim_token_hash, token_hash)
            or row.claim_expires_at is None or utc(row.claim_expires_at) <= now
            or (utc(row.expires_at) <= now and not row.review_authorized_at)
            or row.payment_verified_at is None or row.actual_received_usdt is None or not row.receipt_id):
        raise AppError(code='RECHARGE_EXECUTION_REVIEW_REQUIRED', message='到账、认领或结算状态需重新核对', status_code=409)
    receipt, _ = RechargeReceiptOperations.require_recharge_reservation(session,
        request_id=row.id, receipt_id=row.receipt_id, user_id=row.user_id, now=now)
    if receipt.amount != row.actual_received_usdt:
        raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='到账金额与凭证不符', status_code=409)
    try:
        with localcontext() as context:
            context.prec = 60
            rate = Decimal(str(final_rate))
            if not rate.is_finite() or rate <= 0 or rate >= Decimal('1e14') or rate != rate.quantize(Decimal('.000001')):
                raise InvalidOperation
            amount = (receipt.amount * rate).quantize(Decimal('.01'), rounding=ROUND_HALF_UP)
            if amount <= 0 or amount >= Decimal('1e18'):
                raise InvalidOperation
    except (InvalidOperation, ValueError):
        raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='结算汇率或金额无效', status_code=422) from None
    return row.user_id, amount


def prepare_adjustment_execution(session, *, adjustment, actor_id, now, reserve_policy):
    binding=session.scalar(select(RechargeCreditBinding).where(
        RechargeCreditBinding.adjustment_id==adjustment.id,
        RechargeCreditBinding.state_active=='1').with_for_update())
    support_scoped = adjustment.idempotency_key.startswith('support-recharge:')
    if binding is None:
        if support_scoped:
            raise AppError(code='RECHARGE_PAYMENT_UNVERIFIED', message='财务申请尚未绑定充值订单', status_code=409)
        return None
    row=session.get(RechargeRequest,binding.request_id,with_for_update=True)
    if row is None or (support_scoped and row.expires_at is None):
        raise AppError(code='RECHARGE_PAYMENT_UNVERIFIED', message='充值订单不存在或缺少核验信息', status_code=409)
    if row.expires_at is None: return None
    if not any(reviewer and reviewer != adjustment.submitted_by for reviewer in
            (adjustment.finance_reviewer_id, adjustment.admin_reviewer_id)):
        raise AppError(code='RECHARGE_INDEPENDENT_APPROVAL_REQUIRED', message='充值结算需要独立财务审批', status_code=409)
    if (row.status!='SUBMITTED' or binding.state!='BOUND' or row.claimed_by!=actor_id
        or row.claim_expires_at is None or utc(row.claim_expires_at)<=now
        or (utc(row.expires_at)<=now and not row.review_authorized_at)
        or row.payment_verified_at is None or not row.receipt_id or row.actual_received_usdt is None or binding.final_rate is None
        or adjustment.user_id!=row.user_id
        or (row.actual_received_usdt*binding.final_rate).quantize(Decimal('.01'),rounding=ROUND_HALF_UP)!=adjustment.amount):
        raise AppError(code='RECHARGE_EXECUTION_REVIEW_REQUIRED',message='到账、认领或结算状态需重新核对',status_code=409)
    return prepare_recharge_credit(session,request_id=row.id,receipt_id=row.receipt_id,
        user_id=row.user_id,now=now,reserve_policy=reserve_policy,expected_amount=row.actual_received_usdt)


def finish_adjustment_execution(session, *, prepared, ledger_transaction_id):
    if prepared is not None:
        complete_recharge_credit(session,prepared=prepared,ledger_transaction_id=ledger_transaction_id)


def require_completed_receipt(session, *, request_id, receipt_id, ledger_transaction_id, user_id):
    from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation
    proof=session.get(RechargeReceiptReservation,receipt_id) if receipt_id else None
    if (proof is None or proof.request_id!=request_id or proof.user_id!=user_id
        or proof.state!='CONSUMED' or proof.ledger_transaction_id!=ledger_transaction_id):
        raise AppError(code='RECHARGE_PAYMENT_UNVERIFIED',message='缺少该订单已核验消费的到账凭证',status_code=409)
