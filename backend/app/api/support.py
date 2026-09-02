from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel, ConfigDict, Field

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.modules.support.service import SupportQueueService
from app.modules.friendship.models import Complaint

class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")

class OpenTicketRequest(StrictModel):
    room_id: str = Field(min_length=1, max_length=255)
    skill: str = Field(min_length=1, max_length=80)

class TransferRequest(StrictModel):
    assignee_id: str = Field(min_length=1, max_length=36)

class ComplaintBody(StrictModel):
    category: str = Field(min_length=1, max_length=30)
    description: str = Field(min_length=1, max_length=500)

class PresenceRequest(StrictModel):
    online: bool
    active_tickets: int = Field(ge=0)
    skills: set[str]

def create_support_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/support", tags=["support"])
    queue = SupportQueueService(session_factory)
    rbac = RbacService(session_factory)
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.get("/identities/{user_id}")
    def identity(user_id: str):
        return queue.get_identity(user_id)

    allowed_categories = {"发布不实信息", "涉嫌欺诈骗钱", "存在侵权行为", "骚扰行为", "其他问题"}

    @router.post("/complaints", status_code=201)
    def complaint(body: ComplaintBody, user_id: str = Depends(actor)):
        from uuid import uuid4
        from app.modules.friendship.models import Complaint
        if body.category not in allowed_categories:
            raise AppError(code="COMPLAINT_CATEGORY_INVALID", message="投诉类型无效", status_code=422)
        with session_factory.begin() as session:
            row = Complaint(id=str(uuid4()), user_id=user_id, category=body.category, description=body.description, created_at=datetime.now(timezone.utc))
            session.add(row)
        return {"id": row.id, "category": row.category, "created_at": row.created_at.isoformat()}

    @router.post("/tickets", status_code=201)
    def open_ticket(body: OpenTicketRequest, user_id: str = Depends(actor)):
        return queue.open_ticket(user_id, body.room_id, body.skill)

    @router.post("/tickets/{ticket_id}/assign")
    def assign(ticket_id: str, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SUPPORT_TICKET_ASSIGN)
        return queue.assign_next(ticket_id)

    @router.post("/tickets/{ticket_id}/transfer")
    def transfer(ticket_id: str, body: TransferRequest, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SUPPORT_TICKET_TRANSFER)
        return queue.transfer(ticket_id, body.assignee_id, actor_id=user_id)

    @router.post("/tickets/{ticket_id}/close")
    def close(ticket_id: str, user_id: str = Depends(actor)):
        rbac.require(user_id, Permission.SUPPORT_TICKET_TRANSFER)
        return queue.close(ticket_id, actor_id=user_id)

    @router.put("/agents/{agent_id}/presence", status_code=204)
    def presence(agent_id: str, body: PresenceRequest, user_id: str = Depends(actor)):
        if user_id != agent_id:
            rbac.require(user_id, Permission.SUPPORT_SCOPE_MANAGE)
        queue.set_agent_presence(agent_id, online=body.online, active_tickets=body.active_tickets, skills=body.skills)
        return Response(status_code=204)

    return router
