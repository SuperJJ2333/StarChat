"""Expired-only waiting must not postpone known domain faults."""

from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.funding_scan_models import WalletFundingScanState
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote
from app.modules.wallet.models import WalletControl
from app.modules.wallet.receipt_models import DepositReceiptAnomaly
from test_manual_reserve_monitor import (
    core as core,
    coverage as coverage,
    monitor as monitor,
    digest_cut,
)
from test_manual_expired_resample import setup_wait, expire


def claimed_payout(session, clock, *, age):
    claimed = clock[0] - timedelta(seconds=age)
    session.add(
        ManualPayoutQuote(
            id="preflight-quote",
            user_id="fixture",
            amount=Decimal("10"),
            snapshot={},
            digest="a" * 64,
            created_at=claimed,
            expires_at=claimed + timedelta(minutes=1),
        )
    )
    session.flush()
    session.add(
        ManualPayoutOrder(
            id="preflight-order",
            quote_id="preflight-quote",
            user_id="fixture",
            amount=Decimal("10"),
            digest="a" * 64,
            status="CLAIMED",
            claimed_by="fixture-admin",
            claimed_at=claimed,
            created_at=claimed,
            updated_at=claimed,
        )
    )
    session.get(RedeemabilityReserve, "global").pending_payouts = 1


@pytest.mark.parametrize(
    "fault,code,status",
    [
        ("baseline", "MANUAL_SOURCE_UNHEALTHY", "BLOCKED"),
        ("missing_scan", "MANUAL_COVERAGE_GAP", "BLOCKED"),
        ("regression", "MANUAL_COVERAGE_GAP", "BLOCKED"),
        ("anomaly", "MANUAL_RECEIPT_OBLIGATION_MISSING", "BLOCKED"),
        ("pending_count", "MANUAL_PAYOUT_PENDING_MISMATCH", "BLOCKED"),
        ("old_claim", "MANUAL_PAYOUT_UNCERTAIN", "BLOCKED"),
        ("future_claim", "MANUAL_PAYOUT_UNCERTAIN", "BLOCKED"),
        ("active_claim", "MANUAL_PAYOUT_PENDING", "WAITING"),
        ("deficit", "MANUAL_RESERVE_DEFICIT", "BLOCKED"),
        ("overflow", "MANUAL_RESERVE_OVERFLOW", "BLOCKED"),
        ("external_pause", "MANUAL_WALLET_PAUSED", "BLOCKED"),
        ("coverage_pending", "MANUAL_COVERAGE_PENDING", "WAITING"),
    ],
)
def test_domain_fault_prevents_age_only_wait(core, monitor, fault, code, status):
    service, source, clock, _, sleeps = setup_wait(monitor)
    expire(source, clock)
    if fault == "baseline":
        source.value = digest_cut(source.value, solid_block=service.baseline_height - 1)
    elif fault == "deficit":
        source.value = digest_cut(source.value, balance_units=1)
    elif fault == "overflow":
        source.value = digest_cut(source.value, balance_units=10**30)
    elif fault == "coverage_pending":
        source.value = digest_cut(source.value, max_rowid=source.value.max_rowid + 1)
    with core[1].begin() as session:
        if fault == "missing_scan":
            session.delete(session.get(WalletFundingScanState, "global"))
        elif fault == "regression":
            scan = session.get(WalletFundingScanState, "global")
            scan.cursor_rowid += 1
            scan.source_max_rowid += 1
        elif fault == "anomaly":
            session.add(
                DepositReceiptAnomaly(
                    id="preflight-anomaly",
                    receipt_id=session.scalar(select(core[4].id)),
                    observed_digest="f" * 64,
                    reason_code="EVIDENCE_CONFLICT",
                    observed_at=clock[0],
                )
            )
        elif fault == "pending_count":
            session.get(RedeemabilityReserve, "global").pending_payouts = 1
        elif fault in ("old_claim", "future_claim", "active_claim"):
            claimed_payout(
                session,
                clock,
                age={"old_claim": 301, "future_claim": -1, "active_claim": 1}[fault],
            )
        elif fault == "external_pause":
            control = session.get(WalletControl, "global")
            control.withdrawals_paused, control.pause_reason = True, "EXTERNAL_RISK"
    outcome = service.run_once()
    assert outcome["codes"] == [code]
    assert outcome["status"] == status
    assert sleeps == []
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, "global").observed_at.year == 1970
        if status == "BLOCKED":
            assert (
                session.scalar(
                    select(WalletIncident).where(WalletIncident.code == code)
                )
                is not None
            )
        if fault == "external_pause":
            assert session.get(WalletControl, "global").pause_reason == "EXTERNAL_RISK"
