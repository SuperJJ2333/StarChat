from typing import Annotated
from fastapi import APIRouter,Depends,Header,Query,Response
from pydantic import BaseModel,ConfigDict,Field
from app.core.config import Settings
from app.core.errors import AppError
from app.modules.friendship.service import FriendshipService
from app.modules.identity.tokens import TokenService
from app.modules.identity.profile import ProfileService
class Strict(BaseModel):model_config=ConfigDict(extra='forbid')
class RequestBody(Strict):target_user_id:str=Field(min_length=1,max_length=36);message:str=Field(default='',max_length=200)
class BlockBody(Strict):user_id:str=Field(min_length=1,max_length=36)
class TagBody(Strict):name:str=Field(min_length=1,max_length=64)
class TagPatchBody(Strict):name:str=Field(min_length=1,max_length=64)
class ContactBody(Strict):remark:str|None=Field(default=None,max_length=128);tags:list[str]=Field(default_factory=list,max_length=30);moments_permission:str='DEFAULT'
class FriendProjection(BaseModel):
    user_id:str;username:str;nickname:str;remark:str|None;avatar_url:str|None;matrix_user_id:str|None;moments_permission:str;tags:list[str]
class FriendListResponse(BaseModel):items:list[FriendProjection];next_cursor:str|None=None
class FriendRequestProjection(BaseModel):
    id:str;username:str;nickname:str;avatar_url:str|None;message:str;status:str;requested_at:str
class FriendRequestListResponse(BaseModel):items:list[FriendRequestProjection];next_cursor:str|None=None
class UserSearchProjection(BaseModel):
    user_id:str;username:str;nickname:str;avatar_url:str|None;matrix_user_id:str|None;relationship_state:str
class UserSearchResponse(BaseModel):items:list[UserSearchProjection];next_cursor:str|None=None
def create_friendship_router(settings:Settings,factory,*,avatar_storage):
    router=APIRouter(tags=['friends']);service=FriendshipService(factory,ProfileService(factory,storage=avatar_storage));tokens=TokenService(factory,jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")
    def actor(authorization:Annotated[str|None,Header()]=None):
        if not authorization or not authorization.startswith('Bearer '):raise AppError(code='AUTH_REQUIRED',message='需要登录',status_code=401)
        return str(tokens.decode_access_token(authorization[7:])['sub'])
    @router.post('/friends/requests',status_code=201)
    def request(body:RequestBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.request(user,body.target_user_id,body.message,idempotency_key);return {'id':r.id,'status':r.status}
    @router.get('/friends/requests',response_model=FriendRequestListResponse)
    def requests(user=Depends(actor)):return {'items':service.requests(user),'next_cursor':None}
    @router.post('/friends/requests/{request_id}/accept')
    def accept(request_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.accept(user,request_id,idempotency_key);return {'id':r.id,'status':r.status}
    @router.post('/friends/requests/{request_id}/reject')
    def reject(request_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.reject(user,request_id,idempotency_key);return {'id':r.id,'status':r.status}
    @router.get('/friends',response_model=FriendListResponse)
    def friends(user=Depends(actor)):return {'items':service.list(user),'next_cursor':None}
    @router.patch('/friends/{friend_id}')
    def update(friend_id:str,body:ContactBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.update_profile(user,friend_id,body.remark,body.tags,body.moments_permission,idempotency_key);return {'user_id':r.contact_id,'remark':r.remark,'tags':r.tags.split(',') if r.tags else [],'moments_permission':r.moments_permission}
    @router.delete('/friends/{friend_id}',status_code=204)
    def remove(friend_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        service.delete_friend(user,friend_id,idempotency_key);return Response(status_code=204)
    @router.post('/blocks',status_code=201)
    def block(body:BlockBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        r=service.block(user,body.user_id,idempotency_key);return {'id':r.id,'user_id':r.blocked_id}
    @router.get('/blocks')
    def blocks(user=Depends(actor)):return {'items':service.blocks(user),'next_cursor':None}
    @router.delete('/blocks/{blocked_user_id}',status_code=204)
    def unblock(blocked_user_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        service.unblock(user,blocked_user_id,idempotency_key);return Response(status_code=204)
    @router.post('/contact-tags',status_code=201)
    def create_tag(body:TagBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        row=service.create_tag(user,body.name,idempotency_key);return {'id':row.id,'name':row.name}
    @router.get('/contact-tags')
    def tags(user=Depends(actor)):return {'items':service.tags(user),'next_cursor':None}
    @router.delete('/contact-tags/{tag_id}',status_code=204)
    def delete_tag(tag_id:str,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        service.delete_tag(user,tag_id,idempotency_key);return Response(status_code=204)
    @router.patch('/contact-tags/{tag_id}')
    def rename_tag(tag_id:str,body:TagPatchBody,idempotency_key:Annotated[str,Header(alias='Idempotency-Key')],user=Depends(actor)):
        row=service.rename_tag(user,tag_id,body.name,idempotency_key);return {'id':row.id,'name':row.name}
    @router.get('/users/search',response_model=UserSearchResponse)
    def search(q:Annotated[str,Query(min_length=1,max_length=64)],user=Depends(actor)):return {'items':service.search(user,q),'next_cursor':None}
    return router
