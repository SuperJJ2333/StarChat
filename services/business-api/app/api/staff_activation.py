"""First-use staff activation; same-origin requests, no client destination."""
from fastapi import APIRouter, Request, Response
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
import anyio.to_thread


class ActivationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    username: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=256, repr=False)
    challenge_id: str = Field(min_length=32, max_length=128)
    captcha_answer: str = Field(min_length=1, max_length=16, repr=False)
    channel: Literal['phone', 'email'] | None = None


class ActivationConfirm(BaseModel):
    model_config = ConfigDict(extra='forbid')
    activation_id: str = Field(min_length=32, max_length=64)
    code: str = Field(min_length=6, max_length=6, pattern=r'^\d{6}$', repr=False)


def create_staff_activation_router(*, service, captcha, rate_limiter, origin_check, rate_key):
    router = APIRouter(tags=['identity'])

    @router.post('/auth/staff-activation/challenges', status_code=202)
    async def challenge(body: ActivationRequest, request: Request, response: Response):
        origin_check(request)
        response.headers['Cache-Control'] = 'no-store'
        def run():
            source = request.client.host if request.client else 'unknown'
            rate_limiter.hit(rate_key('auth:staff-activation:send', source), limit=10, window_seconds=900)
            captcha.verify(body.challenge_id, body.captcha_answer)
            rate_limiter.hit(rate_key('auth:staff-activation:password', source, body.username), limit=5, window_seconds=900)
            return service.request(username=body.username, password=body.password, channel=body.channel)
        return await anyio.to_thread.run_sync(run)

    @router.post('/auth/staff-activation/confirm')
    async def confirm(body: ActivationConfirm, request: Request, response: Response):
        origin_check(request)
        response.headers['Cache-Control'] = 'no-store'
        def run():
            rate_limiter.hit(rate_key('auth:staff-activation:confirm',
                request.client.host if request.client else 'unknown'), limit=30, window_seconds=900)
            return service.confirm(activation_id=body.activation_id, code=body.code)
        return await anyio.to_thread.run_sync(run)

    return router
