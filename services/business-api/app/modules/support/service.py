from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, JSON, String, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.support.enums import SupportTicketStatus

class SupportAgentPresence(Base):
    __tablename__ = "support_agent_presence"
    agent_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    online: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    active_tickets: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    skills: Mapped[list[str]] = mapped_column(JSON, nullable=False, default=list)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SupportProfile(Base):
    """Business-API owned public support marker; never derived from Matrix."""
    __tablename__ = "support_profiles"

    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    badge: Mapped[str] = mapped_column(String(6), nullable=False, default="官方客服")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

class SupportTicket(Base):
    __tablename__ = "support_tickets"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    room_id: Mapped[str] = mapped_column(String(255), nullable=False)
    skill: Mapped[str] = mapped_column(String(80), nullable=False)
    status: Mapped[SupportTicketStatus] = mapped_column(String(20), nullable=False)
    assignee_id: Mapped[str | None] = mapped_column(String(36), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)

@dataclass(frozen=True)
class SupportIdentityView:
    user_id: str
    badge: str
    color: str
    support_number: str
    role: RoleCode
    description: str

class SupportQueueService:
    def __init__(self, session_factory):
        self.session_factory = session_factory

    def get_identity(self, user_id: str) -> SupportIdentityView:
        with self.session_factory() as session:
            role = session.scalar(select(UserRole.role_code).where(
                UserRole.user_id == user_id,
                UserRole.role_code.in_((RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_SUPERVISOR)),
            ).order_by(UserRole.assigned_at.desc()))
            profile = session.get(SupportProfile, user_id)
        return self._identity_view(user_id, role or RoleCode.USER, profile.badge if profile is not None else "官方客服")

    @staticmethod
    def _identity_view(user_id: str, role: RoleCode, badge: str) -> SupportIdentityView:
        colors = {RoleCode.SUPPORT_AGENT: "#1677FF", RoleCode.FINANCE_SUPPORT: "#13A8A8", RoleCode.SUPPORT_SUPERVISOR: "#722ED1", RoleCode.SUPER_ADMIN: "#CF1322"}
        return SupportIdentityView(user_id, badge if role != RoleCode.USER else "", colors.get(role, ""), f"CS-{user_id[:8].upper()}", role, "畅聊 ChatFlow 官方支持人员" if role != RoleCode.USER else "")

    def lookup_identities(self, references: list[str]) -> list[dict]:
        """Resolve only real business IDs or stored Matrix IDs; never infer localparts."""
        with self.session_factory() as session:
            users = list(session.scalars(select(User).where(
                ((User.id.in_(references)) | (User.matrix_user_id.in_(references))),
                User.status == AccountStatus.ACTIVE,
            )).all())
            by_reference = {user.id: user for user in users}
            by_reference.update({user.matrix_user_id: user for user in users if user.matrix_user_id})
            user_ids = [user.id for user in users]
            roles: dict[str, RoleCode] = {}
            for row in session.scalars(select(UserRole).where(UserRole.user_id.in_(user_ids), UserRole.role_code.in_((RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_SUPERVISOR))).order_by(UserRole.assigned_at.desc())):
                roles.setdefault(row.user_id, row.role_code)
            badges = support_profile_badges(session, user_ids)
        seen: set[str] = set()
        items = []
        for reference in references:
            user = by_reference.get(reference)
            if user is None or user.id in seen:
                continue
            seen.add(user.id)
            identity = self._identity_view(user.id, roles.get(user.id, RoleCode.USER), badges.get(user.id, "官方客服"))
            items.append({"query_id": reference, "user_id": user.id, "matrix_user_id": user.matrix_user_id,
                          "badge": identity.badge, "role": identity.role, "color": identity.color,
                          "description": identity.description})
        return items

    def open_ticket(self, user_id: str, room_id: str, skill: str) -> SupportTicket:
        now = datetime.now(timezone.utc)
        ticket = SupportTicket(id=str(uuid4()), user_id=user_id, room_id=room_id, skill=skill, status=SupportTicketStatus.OPEN, created_at=now, updated_at=now)
        with self.session_factory.begin() as session:
            session.add(ticket)
        return ticket

    def set_agent_presence(self, agent_id: str, *, online: bool, active_tickets: int, skills: set[str]):
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
            row = session.get(SupportAgentPresence, agent_id)
            if row is None:
                row = SupportAgentPresence(agent_id=agent_id, online=online, active_tickets=active_tickets, skills=sorted(skills), updated_at=now)
                session.add(row)
            else:
                row.online, row.active_tickets, row.skills, row.updated_at = online, active_tickets, sorted(skills), now

    def assign_next(self, ticket_id: str) -> SupportTicket:
        with self.session_factory.begin() as session:
            ticket = session.get(SupportTicket, ticket_id)
            if ticket is None or ticket.status == SupportTicketStatus.CLOSED:
                raise ValueError("ticket unavailable")
            agents = session.scalars(select(SupportAgentPresence).where(SupportAgentPresence.online.is_(True))).all()
            active_role_ids = set(session.scalars(select(UserRole.user_id).where(
                UserRole.role_code.in_((RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_SUPERVISOR))
            )))
            eligible = [a for a in agents if a.agent_id in active_role_ids and ticket.skill in (a.skills or [])]
            if not eligible:
                raise ValueError("no eligible support agent")
            agent = sorted(eligible, key=lambda a: (a.active_tickets, a.updated_at, a.agent_id))[0]
            ticket.assignee_id, ticket.status, ticket.updated_at = agent.agent_id, SupportTicketStatus.ASSIGNED, datetime.now(timezone.utc)
            agent.active_tickets += 1
            session.flush()
            return ticket

    def transfer(self, ticket_id: str, assignee_id: str, *, actor_id: str) -> SupportTicket:
        with self.session_factory.begin() as session:
            ticket = session.get(SupportTicket, ticket_id)
            if ticket is None or ticket.status == SupportTicketStatus.CLOSED:
                raise ValueError("ticket unavailable")
            ticket.assignee_id, ticket.status, ticket.updated_at = assignee_id, SupportTicketStatus.ASSIGNED, datetime.now(timezone.utc)
            session.flush()
            return ticket

    def close(self, ticket_id: str, *, actor_id: str) -> SupportTicket:
        with self.session_factory.begin() as session:
            ticket = session.get(SupportTicket, ticket_id)
            if ticket is None:
                raise ValueError("ticket unavailable")
            ticket.status, ticket.updated_at = SupportTicketStatus.CLOSED, datetime.now(timezone.utc)
            session.flush()
            return ticket


def support_profile_badges(session, user_ids: list[str]) -> dict[str, str]:
    if not user_ids:
        return {}
    return {row.user_id: row.badge for row in session.scalars(select(SupportProfile).where(SupportProfile.user_id.in_(user_ids)))}


def set_support_badge(session, *, user_id: str, badge: str | None, now: datetime) -> str:
    """Public support-domain mutation for an enclosing admin transaction."""
    profile = session.get(SupportProfile, user_id)
    if profile is None:
        profile = SupportProfile(user_id=user_id, badge=badge or "官方客服", updated_at=now)
        session.add(profile)
    elif badge is not None:
        profile.badge, profile.updated_at = badge, now
    return profile.badge
