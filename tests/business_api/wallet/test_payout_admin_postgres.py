"""New admin policy on migrated isolated PostgreSQL, never production."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from decimal import Decimal
import pytest
from sqlalchemy import select,func
from test_support_payout_postgres import core
from test_support_payout import scoped,verified,caibi_order
from test_manual_payouts import request
from test_payout_admin_cancellation import (
 test_admin_cancel_unstarted_releases_once,
 test_admin_cancel_requires_independent_proof_and_current_versions,
 test_admin_cancel_prepared_caibi_restores_original_conversion,
 test_started_without_hash_only_stops_for_review_no_refund,
 test_cancel_rejects_existing_candidate_and_staff,
 test_stop_retains_late_arrival_settlement,
 test_stop_emits_one_transactional_outbox,
 test_historical_released_funds_spent_void_is_atomic,
 test_exact_hash_retry_recovers_receipt_with_original_version,
 test_selection_retry_resumes_durable_locator,
)
from app.core.errors import AppError
from app.modules.wallet.models import WalletLedgerTransaction

@pytest.mark.parametrize('other',['begin','prepare'])
def test_admin_cancel_races_begin_or_prepare(scoped,other):
    core,service,claims=scoped
    order,lease=caibi_order(scoped)
    versions=verified(service,order['id'])
    barrier=Barrier(2)
    def run(operation):
        barrier.wait(timeout=10)
        try:
            common=dict(claims=claims['owner'],order_id=order['id'],idempotency_key='race-'+operation,**versions)
            if operation=='cancel':
                result=service.cancel_unstarted(**common,reason_code='ADMIN_PAYOUT_CANCEL_REQUESTED')
            elif operation=='begin':
                result=service.begin_payment(**common,claim_token=lease['claim_token'],expected_digest=order['digest'],expected_preparation_version=0)
            else:
                result=service.adjust_rate(**common,claim_token=lease['claim_token'],new_rate='8.000000',reason_code='ADMIN_RATE_REVIEWED',expected_preparation_version=0)
            return (operation,result['status'])
        except AppError as error:return (operation,error.code)
    with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(run,['cancel',other]))
    successes=[r for r in results if r[1] in {'CANCELLED','CLAIMED','REQUESTED'}]
    if other=='begin':assert len(successes)==1,results
    else:assert any(r[1]=='CANCELLED' for r in successes),results
    final=core[0].status(user_id='alice',order_id=order['id'])
    held=core[5].balance('HOLD:alice')
    assert held == (Decimal('0') if final['status']=='CANCELLED' else Decimal('20'))
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction).where(
            WalletLedgerTransaction.reason_code=='MANUAL_PAYOUT_ADMIN_CANCELLED',
            WalletLedgerTransaction.scope=='wallet.manual_release')) <= 1
