from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole
from app.modules.support.service import SupportQueueService

@pytest.fixture()
def session_factory():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    yield factory
    engine.dispose()

def test_support_identity_is_server_authoritative(session_factory):
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        session.add(UserRole(id="role-1", user_id="agent-1", role_code=RoleCode.SUPPORT_AGENT, assigned_by="admin", assigned_at=now))
    service = SupportQueueService(session_factory)
    identity = service.get_identity("agent-1")
    assert identity.badge == "官方客服"
    assert identity.support_number.startswith("CS-")
    assert identity.role == RoleCode.SUPPORT_AGENT

def test_queue_assigns_online_least_active_and_transfer_close(session_factory):
    service = SupportQueueService(session_factory)
    ticket = service.open_ticket("user-1", "room-opaque", "billing")
    service.set_agent_presence("agent-a", online=True, active_tickets=2, skills={"billing"})
    service.set_agent_presence("agent-b", online=True, active_tickets=0, skills={"billing"})
    assigned = service.assign_next(ticket.id)
    assert assigned.assignee_id == "agent-b"
    transferred = service.transfer(ticket.id, "agent-a", actor_id="supervisor")
    assert transferred.assignee_id == "agent-a"
    closed = service.close(ticket.id, actor_id="agent-a")
    assert closed.status == "CLOSED"
