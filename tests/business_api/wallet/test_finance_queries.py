from dataclasses import replace
from app.modules.wallet.finance_queries import WalletFinanceQuery

from test_deposit_receipts import core as receipt_core, intent, ingest  # noqa: F401
from test_manual_payouts import core as payout_core, claim, evidence  # noqa: F401


def test_receipt_link_distinguishes_accounting_from_evidence_conflict(receipt_core):
    from app.modules.wallet.finance_queries import WalletFinanceQuery
    query = WalletFinanceQuery(receipt_core[1])
    txid = receipt_core[2].value.txid
    assert query.chain_link(txid, 0) is None
    intent(receipt_core)
    ingest(receipt_core)
    link = query.chain_link(txid, 0)
    assert link['kind'] == 'DEPOSIT'
    assert link['ledger_status'] == 'CREDITED'
    assert link['user_id'] == 'alice'
    assert link['ledger_transaction_id']
    assert link['evidence_status'] == 'VERIFIED'
    receipt_core[2].value = replace(receipt_core[2].value, transfers=())
    ingest(receipt_core)
    conflict = query.chain_link(txid, 0)
    assert conflict['ledger_status'] == 'CREDITED'
    assert conflict['evidence_status'] == 'CONFLICT'


def test_unmatched_deposit_does_not_invent_user(receipt_core):
    from app.modules.wallet.finance_queries import WalletFinanceQuery
    ingest(receipt_core)
    link = WalletFinanceQuery(receipt_core[1]).chain_link(receipt_core[2].value.txid, 0)
    assert link['ledger_status'] == 'REVIEW'
    assert link['user_id'] is None
    assert link['ledger_transaction_id'] is None


def test_payout_candidates_are_not_reported_as_settlement(payout_core):
    from app.modules.wallet.finance_queries import WalletFinanceQuery
    order = claim(payout_core)
    payout_core[0].submit_txid(admin_id='owner', order_id=order['id'], txid='a'*64, idempotency_key='tx')
    query = WalletFinanceQuery(payout_core[1])
    assert query.chain_link('a'*64, 0) is None
    payout_core[6].evidence = evidence(payout_core)
    payout_core[0].reconcile(order_id=order['id'])
    link = query.chain_link('a'*64, 0)
    assert link['kind'] == 'PAYOUT'
    assert link['ledger_status'] == 'SETTLED'
    assert link['user_id'] == 'alice'
    assert link['record_id'] == order['id']
    assert link['ledger_transaction_id']
    details = query.payout(order['id'])
    assert details['settlement_txid'] == 'a'*64
    assert len(details['candidates']) == 1
    assert query.payouts(limit=10)['items'][0]['id'] == order['id']
