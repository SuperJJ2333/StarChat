from hashlib import sha256
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select

from app.core.config import Settings
from app.core.errors import AppError
from app.core.rate_limits import RateLimiter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.matrix_login import MatrixLoginTokenService
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


def public_rate_limit_key(operation: str, source_ip: str, subject: str = "") -> str:
    """Build a non-global, non-identifying bucket for unauthenticated endpoints."""
    digest = sha256(f"{source_ip}\0{subject.casefold()}".encode()).hexdigest()[:32]
    return f"{operation}:{digest}"


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class InvitationRequest(StrictModel):
    invitation_code: str = Field(min_length=1, max_length=128)


class RegisterRequest(StrictModel):
    username: str = Field(min_length=3, max_length=64)
    nickname: str | None = Field(default=None, max_length=64)
    email: str = Field(min_length=3, max_length=320)
    password: str = Field(min_length=12, max_length=256)
    invitation_code: str = Field(min_length=1, max_length=128)


class EmailVerificationRequest(StrictModel):
    registration_session: str = Field(min_length=32, max_length=256)
    code: str | None = Field(default=None)
    token: str | None = Field(default=None, min_length=32, max_length=512)

    @model_validator(mode="after")
    def require_exactly_one_credential(self):
        if (self.code is None) == (self.token is None):
            raise ValueError("code and token are mutually exclusive")
        if self.code is not None and (len(self.code) != 6 or not self.code.isdigit()):
            raise ValueError("请输入 6 位数字验证码")
        return self


class EmailVerificationLinkRequest(StrictModel):
    token: str = Field(min_length=32, max_length=512)


class RegistrationSessionRequest(StrictModel):
    registration_session: str = Field(min_length=32, max_length=256)


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


class MatrixLoginTokenResponse(BaseModel):
    login_token: str
    homeserver: str
    expires_in: int


def create_identity_router(
    settings: Settings,
    session_factory,
    rate_limiter: RateLimiter,
    *,
    matrix_gateway,
) -> APIRouter:
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
        require_session_claims=settings.environment != "test",
    )
    recovery = PasswordRecoveryService(
        session_factory,
        password_hasher=password_hasher,
        token_codec=reset_codec,
    )
    audit = AuditWriter(session_factory)
    matrix_login = MatrixLoginTokenService(
        session_factory,
        gateway=matrix_gateway,
        public_homeserver_url=settings.matrix_public_homeserver_url,
        expires_in=settings.matrix_login_token_expires_in,
    )

    def record_audit(
        request: Request,
        *,
        actor_id: str | None,
        subject_id: str,
        action: str,
        reason_code: str,
        result: str = "SUCCESS",
    ) -> None:
        audit.record(
            actor_id=actor_id,
            subject_type="user",
            subject_id=subject_id,
            action=action,
            result=result,
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
    async def validate_invitation(body: InvitationRequest, request: Request) -> dict:
        rate_limiter.hit(public_rate_limit_key("invitation:validate", request.client.host if request.client else "unknown", body.invitation_code), limit=30, window_seconds=60)
        return {"valid": invitation_service.validate(body.invitation_code)}

    @router.post("/auth/register", status_code=202)
    async def register(
        body: RegisterRequest,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        device_key: Annotated[str | None, Header(alias="X-Device-Key")] = None,
    ) -> dict:
        registration.validate_email_eligible(
            **body.model_dump(),
            idempotency_key=idempotency_key,
        )
        rate_limiter.hit(public_rate_limit_key("auth:register:v2", request.client.host if request.client else "unknown", device_key or body.username), limit=3, window_seconds=3600)
        result = registration.register(
            **body.model_dump(),
            idempotency_key=idempotency_key,
        )
        record_audit(
            request,
            actor_id=result.user_id,
            subject_id=result.user_id,
            action="identity.registration.created",
            reason_code="SELF_REGISTRATION",
        )
        return {
            "registration_session": result.registration_session,
            "status": result.status,
            "resend_after_seconds": result.resend_after_seconds,
        }

    @router.post("/auth/email-verifications/verify", status_code=202)
    async def verify_email(
        body: EmailVerificationRequest,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
    ) -> dict:
        rate_limiter.hit(public_rate_limit_key("auth:email-verification:verify", request.client.host if request.client else "unknown", body.registration_session), limit=20, window_seconds=3600)
        result = email_verification.verify(
            **body.model_dump(),
            idempotency_key=idempotency_key,
        )
        user_id = email_verification.user_id_for_session(body.registration_session)
        record_audit(
            request,
            actor_id=user_id,
            subject_id=user_id,
            action="identity.email.verified",
            reason_code="EMAIL_VERIFICATION",
        )
        return {"status": result.status}

    @router.get("/verify-email", response_class=HTMLResponse)
    async def verification_link_page() -> HTMLResponse:
        return HTMLResponse(
            """<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>六合通邮箱验证</title>
<main><h1>正在验证邮箱…</h1><p id="status">请稍候</p></main>
<script>
(async () => {
  const status = document.getElementById('status');
  const token = new URLSearchParams(location.hash.slice(1)).get('token');
  if (!token) { status.textContent = '验证链接无效'; return; }
  const response = await fetch('/api/v1/auth/email-verifications/link', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({token}),
  });
  status.textContent = response.ok
    ? '邮箱验证成功，请返回六合通登录'
    : '验证链接无效或已过期';
})();
</script>
</html>""",
            headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"},
        )

    @router.post("/auth/email-verifications/link", status_code=202)
    async def verify_email_link(body: EmailVerificationLinkRequest, request: Request) -> dict:
        rate_limiter.hit(public_rate_limit_key("auth:email-verification:link", request.client.host if request.client else "unknown", body.token), limit=20, window_seconds=3600)
        user_id = email_verification.user_id_for_token(body.token)
        result = email_verification.verify_link(body.token)
        record_audit(
            request,
            actor_id=user_id,
            subject_id=user_id,
            action="identity.email.verified",
            reason_code="EMAIL_VERIFICATION_LINK",
        )
        return {"status": result.status}

    @router.post("/auth/email-verifications/resend", status_code=202)
    async def resend_email_verification(
        body: RegistrationSessionRequest,
        request: Request,
        idempotency_key: Annotated[
            str,
            Header(alias="Idempotency-Key", min_length=1, max_length=128),
        ],
        device_key: Annotated[str | None, Header(alias="X-Device-Key")] = None,
    ) -> dict:
        rate_limiter.hit(public_rate_limit_key("auth:email-verification:resend", request.client.host if request.client else "unknown", device_key or body.registration_session), limit=3, window_seconds=3600)
        result = email_verification.resend(
            registration_session=body.registration_session,
            idempotency_key=idempotency_key,
        )
        return {
            "status": result.status,
            "resend_after_seconds": result.resend_after_seconds,
        }

    @router.get("/auth/registrations/{registration_session}")
    async def registration_status(registration_session: str, request: Request) -> dict:
        rate_limiter.hit(public_rate_limit_key("auth:registration:status", request.client.host if request.client else "unknown", registration_session), limit=60, window_seconds=60)
        result = email_verification.status(registration_session)
        return {
            "status": result.status,
            "resend_after_seconds": result.resend_after_seconds,
        }

    @router.post("/auth/login", response_model=TokenResponse)
    async def login(body: LoginRequest, request: Request) -> TokenResponse:
        rate_limiter.hit(
            public_rate_limit_key("auth:login", request.client.host if request.client else "unknown", body.username), limit=10, window_seconds=900
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
    async def refresh(body: RefreshRequest, request: Request) -> TokenResponse:
        rate_limiter.hit(public_rate_limit_key("auth:refresh", request.client.host if request.client else "unknown", body.refresh_token), limit=60, window_seconds=60)
        pair = tokens.rotate(body.refresh_token)
        return TokenResponse(access_token=pair.access_token, refresh_token=pair.refresh_token)

    @router.post(
        "/auth/matrix-login-token",
        response_model=MatrixLoginTokenResponse,
    )
    async def matrix_login_token(
        request: Request,
        claims: Annotated[dict, Depends(current_claims)],
    ) -> MatrixLoginTokenResponse:
        user_id = claims["sub"]
        rate_limiter.hit(
            f"auth:matrix-login-token:{user_id}", limit=20, window_seconds=60
        )
        try:
            result = matrix_login.issue(user_id)
        except AppError as exc:
            record_audit(
                request,
                actor_id=user_id,
                subject_id=user_id,
                action="identity.matrix.login_token.issued",
                reason_code=exc.code,
                result="FAILURE",
            )
            raise
        record_audit(
            request,
            actor_id=user_id,
            subject_id=user_id,
            action="identity.matrix.login_token.issued",
            reason_code="MATRIX_LOGIN_TOKEN",
        )
        return MatrixLoginTokenResponse(
            login_token=result.login_token,
            homeserver=result.homeserver,
            expires_in=result.expires_in,
        )

    @router.post("/auth/logout", status_code=204)
    async def logout(body: RefreshRequest, request: Request) -> Response:
        rate_limiter.hit(public_rate_limit_key("auth:logout", request.client.host if request.client else "unknown", body.refresh_token), limit=60, window_seconds=60)
        tokens.revoke_by_refresh_token(body.refresh_token)
        return Response(status_code=204)

    @router.post("/auth/password/forgot", status_code=202)
    async def forgot(body: ForgotRequest, request: Request) -> dict:
        rate_limiter.hit(public_rate_limit_key("auth:password-forgot", request.client.host if request.client else "unknown", body.email), limit=10, window_seconds=3600)
        recovery.request(body.email)
        return {"accepted": True}

    @router.post("/auth/password/reset", status_code=204)
    async def reset(body: ResetRequest, request: Request) -> Response:
        rate_limiter.hit(public_rate_limit_key("auth:password-reset", request.client.host if request.client else "unknown", body.token), limit=10, window_seconds=3600)
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
