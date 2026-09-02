from typing import Annotated
from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import or_, select

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.friendship.models import Friendship
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService

class Strict(BaseModel):
    model_config = ConfigDict(extra='forbid')

class AutoJoinPreference(Strict):
    enabled: bool

class GroupAutoJoinRequest(Strict):
    room_id: str = Field(min_length=1, max_length=255)
    invitee_user_ids: list[str] = Field(min_length=1, max_length=499)

def create_group_router(settings: Settings, factory, *, matrix_gateway) -> APIRouter:
    router = APIRouter(tags=['groups'])
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes', jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')
    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return str(tokens.decode_access_token(authorization[7:])['sub'])

    @router.get('/profile/privacy')
    def get_privacy(user_id: str = Depends(actor)):
        with factory() as session:
            user = session.get(User, user_id)
            if user is None: raise AppError(code='USER_NOT_FOUND', message='账号不存在', status_code=404)
            return {'auto_allow_group_join': user.auto_allow_group_join}

    @router.put('/profile/privacy/auto-allow-group-join')
    def set_privacy(body: AutoJoinPreference, user_id: str = Depends(actor)):
        with factory.begin() as session:
            user = session.get(User, user_id)
            if user is None: raise AppError(code='USER_NOT_FOUND', message='账号不存在', status_code=404)
            user.auto_allow_group_join = body.enabled
            return {'auto_allow_group_join': user.auto_allow_group_join}

    @router.post('/groups/auto-join')
    def auto_join(body: GroupAutoJoinRequest, idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)], creator_id: str = Depends(actor)):
        requested = list(dict.fromkeys(body.invitee_user_ids))
        with factory() as session:
            users = {user.id: user for user in session.scalars(select(User).where(User.id.in_(requested))).all()}
            friend_ids = set(session.scalars(select(Friendship.user_high_id).where(Friendship.user_low_id == creator_id)).all()) | set(session.scalars(select(Friendship.user_low_id).where(Friendship.user_high_id == creator_id)).all())
            eligible = []
            pending = []
            for invitee_id in requested:
                user = users.get(invitee_id)
                if invitee_id not in friend_ids:
                    raise AppError(code='GROUP_INVITEE_NOT_FRIEND', message='只能邀请好友加入群聊', status_code=403)
                if user is None or user.status != AccountStatus.ACTIVE or not user.matrix_user_id:
                    raise AppError(code='GROUP_INVITEE_UNAVAILABLE', message='群成员账号不可用', status_code=422)
                (eligible if user.auto_allow_group_join else pending).append(user)
        joined = []
        for user in eligible:
            matrix_gateway.join_room_as_user(user.matrix_user_id, body.room_id)
            joined.append(user.id)
        return {'room_id': body.room_id, 'joined_user_ids': joined, 'pending_user_ids': [user.id for user in pending]}
    return router

