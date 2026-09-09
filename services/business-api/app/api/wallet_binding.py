"""Session-scoped binding APIs; external readiness cannot be enabled by clients."""
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.wallet.binding import WalletBindingService


class BindingChallengeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    address: str = Field(min_length=1, max_length=34)
    expected_version: int = Field(ge=0, strict=True)


class BindingConfirmBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    challenge_id: str = Field(min_length=1, max_length=36)
    signature: str = Field(min_length=130, max_length=132, repr=False)
    old_signature: str | None = Field(default=None, min_length=130, max_length=132, repr=False)
    mfa_proof: SecretStr = Field(min_length=1, max_length=256, repr=False)


class BindingStatusResponse(BaseModel):
    status: Literal["ACTIVE", "PENDING", "UNBOUND"]
    id: str | None
    version: int
    masked_address: str | None
    address: str | None = None
    pending_id: str | None
    next_rebind_at: str | None
    binding_enabled: bool
    unavailable_dependencies: list[str]
    rebind_interval_days: Literal[30] = 30


class BindingChallengeResponse(BaseModel):
    id: str
    message: str
    expires_at: str
    protocol: Literal["signMessageV2"]


class BindingConfirmResponse(BaseModel):
    id: str
    status: Literal["PENDING"]
    version: int
    blocked_reason: str


def create_wallet_binding_router(settings, session_factory, *, service=None):
    router = APIRouter(tags=["wallet-binding"])
    domain = settings.wallet_binding_domain
    binding = service or WalletBindingService(session_factory, domain=domain or "binding.invalid")
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or
        "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer,
        require_session_claims=True)

    def actor(response: Response, authorization: Annotated[str | None, Header()] = None):
        response.headers["Cache-Control"] = "no-store"
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        return str(claims["sub"]), str(claims["family_id"])

    def unavailable():
        missing = [] if domain else ["DOMAIN"]
        for name, adapter in [("MFA", binding.mfa_verifier), ("ACCOUNT_PERMISSIONS", binding.permission_verifier),
                              ("INDEPENDENT_FINALITY", binding.barrier_verifier)]:
            if adapter is None:
                if binding.address_registration_enabled and name in {'MFA', 'ACCOUNT_PERMISSIONS'}:
                    continue
                missing.append(name)
        return missing

    def require_ready():
        if unavailable():
            raise AppError(code="WALLET_BINDING_NOT_READY", message="钱包绑定核验服务尚未就绪，请勿充值", status_code=503)

    @router.get("/binding", response_model=BindingStatusResponse)
    def status(identity=Depends(actor)):
        missing = unavailable()
        return {**binding.status(identity[0]), "binding_enabled": not missing,
                "unavailable_dependencies": missing, "rebind_interval_days": 30}

    @router.post("/binding/challenges", response_model=BindingChallengeResponse)
    def challenge(body: BindingChallengeBody,
                  idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)],
                  identity=Depends(actor)):
        require_ready()
        return binding.challenge(user_id=identity[0], session_id=identity[1], address=body.address,
            expected_version=body.expected_version, idempotency_key=idempotency_key)

    @router.post("/binding/confirm", response_model=BindingConfirmResponse)
    def confirm(body: BindingConfirmBody,
                idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)],
                identity=Depends(actor)):
        require_ready()
        return binding.confirm(user_id=identity[0], session_id=identity[1], challenge_id=body.challenge_id,
            signature=body.signature, old_signature=body.old_signature,
            mfa_proof=body.mfa_proof.get_secret_value(), idempotency_key=idempotency_key)

    @router.post('/binding/address', response_model=BindingConfirmResponse)
    def register_address(body: BindingChallengeBody,
            idempotency_key: Annotated[str, Header(alias='Idempotency-Key', min_length=1, max_length=128)],
            identity=Depends(actor)):
        require_ready()
        return binding.register_address(user_id=identity[0], session_id=identity[1],
            address=body.address, expected_version=body.expected_version, idempotency_key=idempotency_key)

    return router
