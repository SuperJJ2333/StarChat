from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from app.core.config import Settings
from app.core.errors import AppError
from app.core.rate_limits import RateLimiter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.recovery import PasswordRecoveryService, PasswordResetTokenCodec
from app.modules.identity.registration import (
    EmailVerificationService,
    RegistrationService,
    VerificationTokenCodec,
)
from app.modules.identity.tokens import TokenService
from app.modules.audit.writer import AuditWriter


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class InvitationRequest(StrictModel):
    invitation_code: str = Field(min_length=1, max_length=128)


class RegisterRequest(StrictModel):
    username: str = Field(min_length=3, max_length=64)
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=12, max_length=256)
    invitation_code: str = Field(min_length=1, max_length=128)


class TokenInput(StrictModel):
    token: str


class LoginRequest(StrictModel):
    username: str
    password: str
    device_key: str = Field(min_length=1, max_length=128)
    device_name: str = Field(min_length=1, max_length=128)


class RefreshRequest(StrictModel):
    refresh_token: str


class ForgotRequest(StrictModel):
    email: str


class ResetRequest(StrictModel):
    token: str
    new_password: str = Field(min_length=12, max_length=256)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int = 900


def create_identity_router(settings: Settings, session_factory, rate_limiter: RateLimiter) -> APIRouter:
    router = APIRouter(tags=["identity"])
    password_hasher = PasswordHasher()
    invitation_service = InvitationService(session_factory)
    verification_codec = VerificationTokenCodec(
        (settings.email_verification_secret or "development-email-verification-secret").encode()
    )
    reset_codec = PasswordResetTokenCodec(
        (settings.password_reset_secret or "development-password-reset-secret").encode()
    )
    registration = RegistrationService(
        session_factory,
        invitation_service=invitation_service,
        password_hasher=password_hasher,
        token_codec=verification_codec,
    )
    email_verification = EmailVerificationService(
        session_factory, token_codec=verification_codec
    )
    tokens = TokenService(
        session_factory,
        jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer,
    )
    recovery = PasswordRecoveryService(
        session_factory,
        password_hasher=password_hasher,
        token_codec=reset_codec,
    )
    audit = AuditWriter(session_factory)

    def record_audit(
        request: Request,
        *,
        actor_id: str | None,
        subject_id: str,
        action: str,
        reason_code: str,
    ) -> None:
        audit.record(
            actor_id=actor_id,
            subject_type="user",
            subject_id=subject_id,
            action=action,
            result="SUCCESS",
            reason_code=reason_code,
            trace_id=getattr(request.state, "trace_id", "unknown"),
            source_ip=request.client.host if request.client else None,
        )

    def current_claims(
        authorization: Annotated[str | None, Header()] = None,
    ) -> dict:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return tokens.decode_access_token(authorization[7:])

    @router.post("/invitations/validate")
    async def validate_invitation(body: InvitationRequest) -> dict:
        rate_limiter.hit("invitation:validate", limit=30, window_seconds=60)
        return {"valid": invitation_service.validate(body.invitation_code)}

    @router.post("/auth/register", status_code=202)
    async def register(body: RegisterRequest, request: Request) -> dict:
        rate_limiter.hit("auth:register", limit=10, window_seconds=3600)
        result = registration.register(**body.model_dump())
        record_audit(
            request,
            actor_id=result.user_id,
            subject_id=result.user_id,
            action="identity.registration.created",
            reason_code="SELF_REGISTRATION",
        )
        return {"user_id": result.user_id, "status": AccountStatus.PENDING_EMAIL}

    @router.post("/auth/verify-email", status_code=202)
    async def verify_email(body: TokenInput, request: Request) -> dict:
        rate_limiter.hit("auth:verify-email", limit=20, window_seconds=3600)
        user_id = email_verification.verify(body.token)
        record_audit(
            request,
            actor_id=user_id,
            subject_id=user_id,
            action="identity.email.verified",
            reason_code="EMAIL_VERIFICATION",
        )
        return {"user_id": user_id, "status": AccountStatus.PENDING_MATRIX}

    @router.post("/auth/login", response_model=TokenResponse)
    async def login(body: LoginRequest, request: Request) -> TokenResponse:
        rate_limiter.hit(
            f"auth:login:{body.username.strip().casefold()}", limit=10, window_seconds=900
        )
        with session_factory() as session:
            user = session.scalar(
                select(User).where(User.username_normalized == body.username.strip().casefold())
            )
            if (
                user is None
                or user.status != AccountStatus.ACTIVE
                or not password_hasher.verify(user.password_hash, body.password)
            ):
                raise AppError(
                    code="CREDENTIALS_INVALID", message="用户名或密码错误", status_code=401
                )
            pair = tokens.issue_pair(
                user_id=user.id,
                device_key=body.device_key,
                display_name=body.device_name,
            )
        record_audit(
            request,
            actor_id=user.id,
            subject_id=user.id,
            action="identity.session.created",
            reason_code="PASSWORD_LOGIN",
        )
        return TokenResponse(access_token=pair.access_token, refresh_token=pair.refresh_token)

    @router.post("/auth/refresh", response_model=TokenResponse)
    async def refresh(body: RefreshRequest) -> TokenResponse:
        rate_limiter.hit("auth:refresh", limit=60, window_seconds=60)
        pair = tokens.rotate(body.refresh_token)
        return TokenResponse(access_token=pair.access_token, refresh_token=pair.refresh_token)

    @router.post("/auth/logout", status_code=204)
    async def logout(body: RefreshRequest) -> Response:
        rate_limiter.hit("auth:logout", limit=60, window_seconds=60)
        tokens.revoke_by_refresh_token(body.refresh_token)
        return Response(status_code=204)

    @router.post("/auth/password/forgot", status_code=202)
    async def forgot(body: ForgotRequest) -> dict:
        rate_limiter.hit("auth:password-forgot", limit=10, window_seconds=3600)
        recovery.request(body.email)
        return {"accepted": True}

    @router.post("/auth/password/reset", status_code=204)
    async def reset(body: ResetRequest, request: Request) -> Response:
        rate_limiter.hit("auth:password-reset", limit=10, window_seconds=3600)
        user_id = recovery.reset(body.token, body.new_password)
        record_audit(
            request,
            actor_id=user_id,
            subject_id=user_id,
            action="identity.password.reset",
            reason_code="PASSWORD_RESET",
        )
        return Response(status_code=204)

    @router.get("/devices")
    async def devices(claims: Annotated[dict, Depends(current_claims)]) -> list[dict]:
        rate_limiter.hit(f"devices:list:{claims['sub']}", limit=60, window_seconds=60)
        return [
            {
                "id": device.id,
                "display_name": device.display_name,
                "last_seen_at": device.last_seen_at,
            }
            for device in tokens.list_devices(claims["sub"])
        ]

    @router.delete("/devices/{device_id}", status_code=204)
    async def revoke_device(
        device_id: str,
        request: Request,
        claims: Annotated[dict, Depends(current_claims)],
    ) -> Response:
        rate_limiter.hit(f"devices:revoke:{claims['sub']}", limit=30, window_seconds=60)
        tokens.revoke_device(user_id=claims["sub"], device_id=device_id)
        record_audit(
            request,
            actor_id=claims["sub"],
            subject_id=claims["sub"],
            action="identity.device.revoked",
            reason_code="USER_DEVICE_REVOCATION",
        )
        return Response(status_code=204)

    return router
