"""Late commit guards must roll back manual deposit allocations atomically."""
from __future__ import annotations

from datetime import timedelta, timezone

import pytest
from sqlalchemy import event, func, select
from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.models import WalletLedgerTransaction
from app.modules.wallet.repair_models import ManualDepositCase, RepairCommand
from test_manual_deposit_cases import _service, manual_core


def _approved_preview(core, *, suffix: str):
    service, receipt = _service(core)
    case = service.create(
        actor_id="owner", receipt_id=receipt["id"], user_id="alice", reason_detail="提交末端防护验证",
        ownership_attestation=True, idempotency_key=f"case-{suffix}", authorize=lambda session: lambda: None,
    )
    service.decide(
        actor_id="owner", case_id=case["case_id"], decision="APPROVED", reason_detail="负责人确认",
        confirmed=True, idempotency_key=f"decision-{suffix}", authorize=lambda session: lambda: None,
    )
    preview = service.preview(actor_id="owner", case_id=case["case_id"], authorize=lambda session: lambda: None)
    assert preview["status"] == "VALIDATED"
    return service, receipt, case, preview


def _assert_execution_rolled_back(core, receipt_id: str):
    with core[1]() as session:
        receipt = session.get(core[4], receipt_id)
        assert receipt.status == "REVIEW"
        assert receipt.pending_obligation is True
        assert receipt.ledger_transaction_id is None
        assert receipt.manual_case_id is None
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 0
        assert session.scalar(select(func.count()).select_from(RepairCommand)) == 0
        assert session.get(RedeemabilityReserve, "global").usdt_liability == 10


def _execute(service, case, preview, *, suffix: str):
    return service.execute(
        actor_id="owner", case_id=case["case_id"], preview_id=preview["preview_id"], digest=preview["digest"],
        expected_version=1, operation_id=f"commit-guard-{suffix}", idempotency_key=f"execute-{suffix}",
        authorize=lambda session: lambda: None,
    )


def test_execute_rolls_back_when_clock_becomes_untrusted_after_flush(manual_core):
    service, receipt, case, preview = _approved_preview(manual_core, suffix="clock")
    state = {"trusted": True}
    service.clock_trusted = lambda: state["trusted"]

    def after_flush(session, flush_context):
        state["trusted"] = False

    event.listen(Session, "after_flush", after_flush)
    try:
        with pytest.raises(AppError) as error:
            _execute(service, case, preview, suffix="clock")
    finally:
        event.remove(Session, "after_flush", after_flush)
    assert error.value.code == "EVIDENCE_EXPIRED"
    _assert_execution_rolled_back(manual_core, receipt["id"])


def test_execute_rolls_back_when_preview_expires_after_flush(manual_core):
    service, receipt, case, preview = _approved_preview(manual_core, suffix="preview")
    clock = {"now": manual_core[5] + timedelta(seconds=3)}
    service.clock = service._guard.clock = lambda: clock["now"]

    def after_flush(session, flush_context):
        clock["now"] = clock["now"] + timedelta(seconds=91)

    event.listen(Session, "after_flush", after_flush)
    try:
        with pytest.raises(AppError) as error:
            _execute(service, case, preview, suffix="preview")
    finally:
        event.remove(Session, "after_flush", after_flush)
    assert error.value.code == "EVIDENCE_EXPIRED"
    _assert_execution_rolled_back(manual_core, receipt["id"])


def test_execute_rolls_back_when_proof_expires_after_flush(manual_core, monkeypatch):
    from app.modules.wallet import manual_deposit_cases

    service, receipt, case, preview = _approved_preview(manual_core, suffix="proof")
    state = {"fresh": True}
    monkeypatch.setattr(manual_deposit_cases, "transaction_evidence_fresh", lambda proof, now: state["fresh"])

    def after_flush(session, flush_context):
        state["fresh"] = False

    event.listen(Session, "after_flush", after_flush)
    try:
        with pytest.raises(AppError) as error:
            _execute(service, case, preview, suffix="proof")
    finally:
        event.remove(Session, "after_flush", after_flush)
    assert error.value.code == "EVIDENCE_EXPIRED"
    _assert_execution_rolled_back(manual_core, receipt["id"])


def test_execute_rolls_back_when_reserve_becomes_stale_after_flush(manual_core, monkeypatch):
    from app.modules.wallet import manual_deposit_cases

    service, receipt, case, preview = _approved_preview(manual_core, suffix="reserve")
    original_lock_budget = manual_deposit_cases.lock_budget
    calls = 0
    state = {"flushed": False, "late_hits": 0}

    def after_flush(session, flush_context):
        state["flushed"] = True

    def stale_final_budget(session):
        nonlocal calls
        calls += 1
        reserve = original_lock_budget(session)
        if state["flushed"]:
            state["late_hits"] += 1
            reserve.observed_at = service.clock() - timedelta(seconds=121)
        return reserve

    monkeypatch.setattr(manual_deposit_cases, "lock_budget", stale_final_budget)
    event.listen(Session, "after_flush", after_flush)
    try:
        with pytest.raises(AppError) as error:
            _execute(service, case, preview, suffix="reserve")
    finally:
        event.remove(Session, "after_flush", after_flush)
    assert calls == 4
    assert state == {"flushed": True, "late_hits": 1}
    assert error.value.code == "RESERVE_UNAVAILABLE"
    _assert_execution_rolled_back(manual_core, receipt["id"])
    with manual_core[1]() as session:
        observed_at = session.get(RedeemabilityReserve, "global").observed_at
        assert observed_at.replace(tzinfo=timezone.utc) == manual_core[5]


@pytest.mark.parametrize("decision", [None, "REJECTED"])
def test_execute_rejects_unapproved_or_rejected_case_preview_without_writes(manual_core, decision):
    service, receipt = _service(manual_core)
    case = service.create(
        actor_id="owner", receipt_id=receipt["id"], user_id="alice", reason_detail="审批门禁验证",
        ownership_attestation=True, idempotency_key=f"case-{decision}", authorize=lambda session: lambda: None,
    )
    if decision:
        service.decide(
            actor_id="owner", case_id=case["case_id"], decision=decision, reason_detail="拒绝", confirmed=True,
            idempotency_key=f"decision-{decision}", authorize=lambda session: lambda: None,
        )
    preview = service.preview(actor_id="owner", case_id=case["case_id"], authorize=lambda session: lambda: None)
    assert "MANUAL_CASE_NOT_APPROVED" in preview["blockers"]
    with pytest.raises(AppError) as error:
        _execute(service, case, preview, suffix=f"{decision}-blocked")
    assert error.value.code == "MANUAL_CASE_NOT_APPROVED"
    _assert_execution_rolled_back(manual_core, receipt["id"])


def test_create_rejects_manual_case_when_matching_ordinary_intent_exists(manual_core):
    from app.modules.wallet.funding_models import DepositIntent

    service, receipt = _service(manual_core)
    ordinary = manual_core[3].create(
        user_id="alice", expected_amount="10.000000", expected_binding_version=1, idempotency_key="ordinary-open"
    )
    with pytest.raises(AppError) as error:
        service.create(
            actor_id="owner", receipt_id=receipt["id"], user_id="alice", reason_detail="普通订单仍然可用",
            ownership_attestation=True, idempotency_key="manual-blocked-by-ordinary", authorize=lambda session: lambda: None,
        )
    assert error.value.code == "ORDINARY_INTENT_AVAILABLE"
    with manual_core[1]() as session:
        assert session.get(DepositIntent, ordinary["id"]).status == "OPEN"
        assert session.scalar(select(func.count()).select_from(ManualDepositCase)) == 0
    _assert_execution_rolled_back(manual_core, receipt["id"])
