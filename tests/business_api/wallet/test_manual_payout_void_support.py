"""The official owner may compensate a support agent's unbroadcast payout."""
from datetime import timedelta, timezone
from decimal import Decimal
from sqlalchemy import update

from test_manual_payouts import core, request  # noqa: F401
from test_support_payout import scoped, verified  # noqa: F401
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.support_payout import SupportPayoutState


def test_official_owner_voids_support_claim_without_rewriting_claimant(scoped):
    core, support, claims = scoped
    payout, factory, clock = core[:3]
    order = request(core)
    lease = support.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='support-lease')
    support.begin_payment(claims=claims['owner'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'], idempotency_key='support-begin', **verified(support, order['id']))
    # Seed historical staff claimant; current APIs forbid creating this state.
    with factory.begin() as session:
        session.execute(update(ManualPayoutOrder).where(ManualPayoutOrder.id == order['id']).values(claimed_by='bob',status='UNKNOWN'))
        state=session.get(SupportPayoutState, order['id']); state.claimed_by='bob'
    assert payout.reconcile(order_id=order['id'])['status'] == 'UNKNOWN'
    with factory() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        original_claimant, original_claimed_at = row.claimed_by, row.claimed_at
        version = row.version
    assert original_claimant == 'bob'
    proof = dict(source_id='official-observer', observation_id='support-observation',
        checkpoint=int(clock[0].timestamp()*1000), observed_at=clock[0],
        scanned_from=int(original_claimed_at.replace(tzinfo=timezone.utc).timestamp()*1000),
        reconciliation_status='SOURCE_MATCHED', matching_outflows=0, suspicious_outflows=0,
        fresh_until_ms=int((clock[0]+timedelta(seconds=60)).timestamp()*1000), max_rowid=100)
    result = payout.void_unbroadcast(admin_id='owner', order_id=order['id'], expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED', never_signed=True, never_broadcast=True,
        idempotency_key='support-void', evidence=proof, authorize=lambda session: lambda: None,
        verify_evidence=lambda session, evidence: True)
    assert result['status'] == 'VOIDED'
    assert result['processing_stage'] == 'VOIDED'
    assert payout.wallet_ledger.balance('HOLD:alice') == Decimal('0')
    assert support.detail(claims=claims['owner'], order_id=order['id'])['processing_stage'] == 'VOIDED'
    clock[0] += timedelta(hours=2)
    assert support.expire_orders() == 0
    with factory() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        support_state = session.get(SupportPayoutState, order['id'])
        assert (row.claimed_by, row.claimed_at) == (original_claimant, original_claimed_at)
        assert support_state.claimed_by == 'bob' and support_state.execution_started_at is not None
        assert support_state.review_required is False
        assert session.get(RedeemabilityReserve, 'global').pending_payouts == 0
