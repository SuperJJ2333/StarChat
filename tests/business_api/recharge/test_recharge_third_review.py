"""Third review: uncertain money must remain bound; review projections stay exact."""
from decimal import Decimal

import pytest
from sqlalchemy import select
from test_recharge_binding import env, _execute
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.recharge.models import RechargeCreditBinding, RechargeRequest


def _needs_review(factory, recharge):
    bound = recharge.bind_finance_adjustment(request_id="req-1", adjustment_id="adj-1",
        actor_id="agent", final_rate="1")
    with factory.begin() as session:
        session.get(RechargeCreditBinding, bound["id"]).state = "NEEDS_REVIEW"
    return bound


@pytest.mark.parametrize("corruption", ["missing", "rejected"])
def test_uncertain_or_contradictory_command_cannot_release_paid_money(env, corruption):
    factory, ledger, recharge = env
    _needs_review(factory, recharge)
    _execute(factory, ledger)
    with factory.begin() as session:
        command = session.get(AdjustmentRequest, "adj-1")
        if corruption == "missing":
            session.delete(command)
        else:
            command.status = "REJECTED"
    with pytest.raises(AppError) as caught:
        recharge.release_review_binding(request_id="req-1", actor_id="finance", reason="check evidence")
    assert caught.value.code == "RECHARGE_RELEASE_EVIDENCE_REQUIRED"
    with factory() as session:
        assert session.scalar(select(RechargeCreditBinding.state_active)) == "1"


def test_review_preserves_real_actor_identity(env):
    factory, ledger, recharge = env
    _needs_review(factory, recharge)
    _execute(factory, ledger)
    actor = "12345678-1234-1234-1234-123456789abc"
    result = recharge.retry_review_registration(request_id="req-1", actor_id=actor)
    assert result["decided_by"] == actor


def test_review_queue_keeps_binding_settlement_snapshot(env):
    factory, _, recharge = env
    _needs_review(factory, recharge)
    item = recharge.review_queue()[0]
    assert Decimal(item["final_rate"]) == Decimal("1")
    assert Decimal(item["final_caibi_amount"]) == Decimal("50")


def test_history_shows_completed_binding(env):
    factory, ledger, recharge = env
    _needs_review(factory, recharge)
    _execute(factory, ledger)
    recharge.complete_bound(request_id="req-1")
    item = recharge.admin_requests()["items"][0]
    assert item["binding_state"] == "REGISTERED"


@pytest.mark.parametrize("cursor", ["2026-09-22", "2026-09-22|", "2026-09-22|id|extra"])
def test_malformed_cursor_is_rejected(env, cursor):
    _, _, recharge = env
    with pytest.raises(AppError) as caught:
        recharge.admin_requests(cursor=cursor)
    assert caught.value.code == "RECHARGE_CURSOR_INVALID"


def test_review_release_replay_is_idempotent(env):
    factory, _, recharge = env
    bound = _needs_review(factory, recharge)
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-1").status = "REJECTED"
    kwargs = dict(request_id="req-1", actor_id="finance", reason="confirmed rejected", idempotency_key="review-release")
    first = recharge.release_review_binding(**kwargs)
    assert recharge.release_review_binding(**kwargs) == first
    with factory() as session:
        assert len(session.scalars(select(OutboxEvent).where(
            OutboxEvent.aggregate_id == bound["id"], OutboxEvent.event_type == "recharge.binding_released")).all()) == 1


@pytest.mark.parametrize("action", ["retry", "release"])
def test_review_rejects_stale_binding_identity(env, action):
    factory, _, recharge = env
    _needs_review(factory, recharge)
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-1").status = "REJECTED"
    with pytest.raises(AppError) as caught:
        if action == "retry":
            recharge.retry_review_registration(request_id="req-1", actor_id="finance", expected_binding_id="old-binding")
        else:
            recharge.release_review_binding(request_id="req-1", actor_id="finance", reason="confirmed rejected",
                idempotency_key="old-key", expected_binding_id="old-binding")
    assert caught.value.code == "RECHARGE_BINDING_CHANGED"
    with factory() as session:
        assert session.scalar(select(RechargeCreditBinding.state_active)) == "1"


def test_retry_rejected_command_with_money_keeps_binding(env):
    factory, ledger, recharge = env
    _needs_review(factory, recharge)
    _execute(factory, ledger)
    with factory.begin() as session:
        command = session.get(AdjustmentRequest, "adj-1")
        command.status = "REJECTED"
        command.ledger_transaction_id = None  # lost pointer must not hide durable money
    result = recharge.retry_review_registration(request_id="req-1", actor_id="finance")
    assert result["binding_state"] == "NEEDS_REVIEW"


def test_queue_pages_equal_timestamps_without_duplicates(env):
    factory, _, recharge = env
    bound = _needs_review(factory, recharge)
    with factory.begin() as session:
        original = session.get(RechargeCreditBinding, bound["id"])
        for index in range(3):
            request = RechargeRequest(id=f"page-{index}", user_id="alice", amount_usdt=Decimal("50"),
                status="SUBMITTED", created_at=original.created_at, updated_at=original.updated_at)
            session.add(request)
            session.flush()
            session.add(RechargeCreditBinding(id=f"page-binding-{index}", request_id=request.id,
                adjustment_id=f"page-adjustment-{index}", state="NEEDS_REVIEW", state_active="1",
                bound_by="agent", created_at=original.created_at, updated_at=original.updated_at))
    ids, cursor = [], None
    for _ in range(4):
        page = recharge.review_queue_page(cursor=cursor, limit=1)
        ids.extend(item["id"] for item in page["items"])
        cursor = page["next_cursor"]
    assert cursor is None and len(ids) == len(set(ids)) == 4


def test_release_replay_rejects_changed_payload(env):
    factory, _, recharge = env
    bound = _needs_review(factory, recharge)
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-1").status = "REJECTED"
    recharge.release_review_binding(request_id="req-1", actor_id="finance", reason="confirmed rejected",
        expected_binding_id=bound["id"], idempotency_key="release-key")
    with pytest.raises(AppError) as caught:
        recharge.release_review_binding(request_id="req-1", actor_id="finance", reason="different reason",
            expected_binding_id=bound["id"], idempotency_key="release-key")
    assert caught.value.code == "IDEMPOTENCY_KEY_REUSED"
