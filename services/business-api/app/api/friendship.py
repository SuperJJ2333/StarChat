from typing import Annotated
from fastapi import APIRouter,Depends,Header,Query
from pydantic import BaseModel,ConfigDict,Field
from app.core.config import Settings
from app.core.errors import AppError
from app.modules.friendship.service import FriendshipService
from app.modules.identity.tokens import TokenService
class Strict(BaseModel):model_config=ConfigDict(extra='forbid')
class RequestBody(Strict):target_user_id:str=Field(min_length=1,max_length=36);message:str=Field(default='',max_length=200)
class BlockBody(Strict):user_id:str=Field(min_length=1,max_length=36)
def create_friendship_router(settings:Settings,factory):
    router=APIRouter(tags=['friends']);service=FriendshipService(factory);tokens=TokenService(factory,jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',jwt_issuer=settings.jwt_issuer)
    def actor(authorization:Annotated[str|None,Header()]=None):
        if not authorization or not authorization.startswith('Bearer '):raise AppError(code='AUTH_REQUIRED',message='需要登录',status_code=401)
        return str(tokens.decode_access_token(authorization[7:])['sub'])
    @router.post('/friends/requests',status_code=201)
    def request(body:RequestBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.request(user,body.target_user_id,body.message,idempotency_key);return {'id':r.id,'status':r.status}
    @router.post('/friends/requests/{request_id}/accept')
    def accept(request_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.accept(user,request_id,idempotency_key);return {'id':r.id,'status':r.status}
    @router.get('/friends')
    def friends(user=Depends(actor)):return {'items':service.list(user),'next_cursor':None}
    @router.post('/blocks',status_code=201)
    def block(body:BlockBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.block(user,body.user_id,idempotency_key);return {'id':r.id,'user_id':r.blocked_id}
    @router.get('/users/search')
    def search(q:Annotated[str,Query(min_length=1,max_length=64)],user=Depends(actor)):return {'items':service.search(user,q),'next_cursor':None}
    return router
