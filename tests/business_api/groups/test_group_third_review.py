"""Third review: adjudication must not invent negative external evidence."""
import pytest
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.audit.models import AuditEvent
from app.modules.groups.models import GroupTransferIntent
from .test_group_transfer_coordination import env


def request(env, key="third"):
    return env[1].request(room_id="!room:x", requester_user_id="owner",
        current_owner_user_id="owner", new_owner_user_id="newowner", idempotency_key=key)


def pending(env):
    intent = request(env)
    env[2].apply_on_send = False
    env[1].advance(intent_id=intent["id"])
    return intent["id"]


def test_confirm_applied_promotes_review_stage_and_completes(env):
    intent_id = pending(env)
    env[4].advance(seconds=180)
    env[1].recover_batch()
    env[2].power_users = {"@newowner:x": 100, "@owner:x": 0}
    result = env[1].review_intent(intent_id=intent_id, action="confirm_applied", actor_id="admin")
    assert result["stage"] == "COMPLETED"
    assert env[3].get("!room:x").owner_user_id == "newowner"
    assert env[1].review_intent(intent_id=intent_id, action="confirm_applied", actor_id="admin")["stage"] == "COMPLETED"
    with env[0]() as session:
        assert len(session.scalars(select(AuditEvent).where(AuditEvent.action == "group.owner_transferred")).all()) == 1


def test_old_owner_snapshot_does_not_prove_send_never_applied(env):
    intent_id = pending(env)
    with pytest.raises(AppError) as error:
        env[1].review_intent(intent_id=intent_id, action="fail_unapplied", actor_id="admin")
    assert error.value.code == "GROUP_TRANSFER_UNPROVEN_UNAPPLIED"


def test_late_failure_cannot_resurrect_reviewed_intent(env):
    intent_id = pending(env)
    with env[0]() as session:
        token = session.get(GroupTransferIntent, intent_id).claim_token
    env[4].advance(seconds=180)
    env[1].recover_batch()
    result = env[1]._record_failure(intent_id, token)
    assert result["stage"] == "NEEDS_REVIEW"


def test_proven_presend_failure_can_release_and_new_request_can_start(env):
    intent_id = request(env)["id"]
    env[2].members.remove("@newowner:x")
    assert env[1].advance(intent_id=intent_id)["stage"] == "NEEDS_REVIEW"
    assert not env[2].send_calls
    result = env[1].review_intent(intent_id=intent_id, action="fail_unapplied", actor_id="admin")
    assert result["stage"] == "FAILED"
    assert env[1].review_intent(intent_id=intent_id, action="fail_unapplied", actor_id="admin")["stage"] == "FAILED"
    with env[0]() as session:
        assert len(session.scalars(select(AuditEvent).where(AuditEvent.action == "group.transfer_intent_failed")).all()) == 1
    env[2].members.add("@newowner:x")
    assert request(env, key="after-safe-release")["stage"] == "VALIDATED"


def test_legacy_failed_unknown_send_remains_quarantined(env):
    intent_id = pending(env)
    with env[0].begin() as session:
        row = session.get(GroupTransferIntent, intent_id)
        row.stage, row.last_error_code = "FAILED", "REVIEW_CONFIRMED_UNAPPLIED"
    with pytest.raises(AppError):
        request(env, key="after-unsafe-release")


def test_paused_send_cannot_be_failed_then_apply_after_release(env):
    intent_id = request(env)["id"]
    def paused_send(users, content):
        env[4].advance(seconds=180)
        env[1].recover_batch()
        with pytest.raises(AppError) as error:
            env[1].review_intent(intent_id=intent_id, action="fail_unapplied", actor_id="admin")
        assert error.value.code == "GROUP_TRANSFER_UNPROVEN_UNAPPLIED"
        with pytest.raises(AppError):
            request(env, key="while-network-unresolved")
    env[2].send_behavior = paused_send
    env[1].advance(intent_id=intent_id)
    assert env[3].get("!room:x").owner_user_id == "owner"
    assert env[1].review_intent(intent_id=intent_id, action="confirm_applied", actor_id="admin")["stage"] == "COMPLETED"


def test_confirmation_crash_retains_audit_and_retry_completes_once(env, monkeypatch):
    intent_id = pending(env)
    env[2].power_users = {"@newowner:x": 100, "@owner:x": 0}
    complete = env[1].complete
    def interrupted(**kwargs):
        raise RuntimeError("process interrupted before completion")
    monkeypatch.setattr(env[1], "complete", interrupted)
    with pytest.raises(RuntimeError):
        env[1].review_intent(intent_id=intent_id, action="confirm_applied", actor_id="admin")
    monkeypatch.setattr(env[1], "complete", complete)
    assert env[1].review_intent(intent_id=intent_id, action="confirm_applied", actor_id="admin")["stage"] == "COMPLETED"
    with env[0]() as session:
        audit = session.scalars(select(AuditEvent).where(AuditEvent.action == "group.transfer_intent_confirmed")).all()
        assert len(audit) == 1 and audit[0].actor_id == "admin"
