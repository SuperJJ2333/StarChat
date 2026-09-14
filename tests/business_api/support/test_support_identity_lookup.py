from datetime import datetime, timedelta, timezone

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole


def test_support_identity_prefers_support_role_over_newer_user_role_and_default_badge():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    from app.modules.support.service import SupportQueueService
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add_all([
            UserRole(id="support-role", user_id="agent-1", role_code=RoleCode.SUPPORT_AGENT, assigned_by="admin", assigned_at=now),
            UserRole(id="user-role", user_id="agent-1", role_code=RoleCode.USER, assigned_by="admin", assigned_at=now + timedelta(seconds=1)),
        ])
    identity = SupportQueueService(factory).get_identity("agent-1")
    assert identity.role == RoleCode.SUPPORT_AGENT
    assert identity.badge == "官方客服"
    engine.dispose()


def test_assign_next_skips_presence_after_all_support_roles_are_removed():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    from app.modules.support.service import SupportQueueService
    queue = SupportQueueService(factory)
    queue.set_agent_presence("former-agent", online=True, active_tickets=0, skills={"billing"})
    ticket = queue.open_ticket("customer", "!room:test", "billing")
    try:
        queue.assign_next(ticket.id)
    except ValueError as exc:
        assert str(exc) == "no eligible support agent"
    else:
        raise AssertionError("removed support identity remained assignable")
    engine.dispose()
