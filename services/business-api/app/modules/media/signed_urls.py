"""Signed URLs (Phase 4.4, ADR-003).

A signed URL is a *proof of a grant*, bound to the object, the variant, the subject and an
expiry the **server** chooses. Properties enforced here:

* the client cannot influence the lifetime: there is no ``expires_in`` parameter anywhere in
  the Phase 4 API, and the codec only accepts a server-computed TTL;
* ``private`` tokens additionally require the caller's identity to equal the token subject,
  so forwarding a private URL to somebody else is useless;
* ``audience`` tokens may be forwarded inside the audience (the frozen, accepted trade-off)
  but they stay revocable, because verification re-checks the grant version and state;
* the signature covers every claim, so a tampered field fails closed;
* the token carries no digest, storage path, file name or token of its own — only opaque
  identifiers and enums — so it is safe if it ends up in a log.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from app.core.errors import AppError
from app.modules.media.domain import (
    Permission,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.metrics import media_platform_metrics

#: Bump when the claim set changes; verification rejects unknown versions.
TOKEN_VERSION = 1


@dataclass(frozen=True, slots=True)
class SignedToken:
    media_id: str
    variant_kind: VariantKind
    subject: str
    aud_scope: str | None
    permission: Permission
    tier: VisibilityTier
    expires_at: datetime
    jti: str
    grant_id: str | None
    grant_version: int | None
    single_use: bool
    key_version: int


def _b64encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


class MediaSignedUrlCodec:
    def __init__(
        self,
        *,
        secret: str | None,
        key_version: int = 1,
        now_factory=lambda: datetime.now(timezone.utc),
        clock=time.time,
    ) -> None:
        self._secret = secret
        self._key_version = key_version
        self._now = now_factory
        self._clock = clock

    @property
    def available(self) -> bool:
        return bool(self._secret)

    def _require_secret(self) -> bytes:
        if not self._secret:
            # Fail closed: never sign with a default or development key.
            raise AppError(
                code="MEDIA_SIGNING_UNAVAILABLE",
                message="媒体签名服务不可用",
                status_code=503,
            )
        return self._secret.encode("utf-8")

    # ------------------------------------------------------------------ #
    # Mint / verify
    # ------------------------------------------------------------------ #
    def mint(
        self,
        *,
        media_id: str,
        variant_kind: VariantKind,
        subject: str,
        tier: VisibilityTier,
        ttl_seconds: int,
        permission: Permission = Permission.READ,
        aud_scope: str | None = None,
        grant_id: str | None = None,
        grant_version: int | None = None,
        single_use: bool = False,
    ) -> tuple[str, SignedToken]:
        secret = self._require_secret()
        ttl = max(1, int(ttl_seconds))
        expires_at = self._now() + timedelta(seconds=ttl)
        token = SignedToken(
            media_id=media_id,
            variant_kind=variant_kind,
            subject=subject,
            aud_scope=aud_scope,
            permission=permission,
            tier=tier,
            expires_at=expires_at,
            jti=secrets.token_hex(8),
            grant_id=grant_id,
            grant_version=grant_version,
            single_use=single_use,
            key_version=self._key_version,
        )
        claims = {
            "v": TOKEN_VERSION,
            "kv": self._key_version,
            "m": token.media_id,
            "k": token.variant_kind.value,
            "s": token.subject,
            "a": token.aud_scope,
            "p": token.permission.value,
            "t": token.tier.value,
            "e": int(expires_at.timestamp()),
            "j": token.jti,
            "g": token.grant_id,
            "gv": token.grant_version,
            "su": token.single_use,
        }
        body = _b64encode(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode())
        signature = _b64encode(hmac.new(secret, body.encode("ascii"), hashlib.sha256).digest())
        media_platform_metrics.increment("signed_url_issued")
        return f"{body}.{signature}", token

    def verify(self, token: str, *, caller_id: str | None) -> SignedToken:
        secret = self._require_secret()
        try:
            body, signature = token.split(".", 1)
        except ValueError:
            self._reject("malformed")
        expected = _b64encode(hmac.new(secret, body.encode("ascii"), hashlib.sha256).digest())
        if not hmac.compare_digest(expected, signature):
            self._reject("bad_signature")
        try:
            claims = json.loads(_b64decode(body))
        except (ValueError, TypeError):
            self._reject("malformed")
        if int(claims.get("v", 0)) != TOKEN_VERSION or int(claims.get("kv", 0)) != self._key_version:
            self._reject("unsupported_version")
        try:
            parsed = SignedToken(
                media_id=str(claims["m"]),
                variant_kind=VariantKind(claims["k"]),
                subject=str(claims["s"]),
                aud_scope=claims.get("a"),
                permission=Permission(claims["p"]),
                tier=VisibilityTier(claims["t"]),
                expires_at=datetime.fromtimestamp(int(claims["e"]), tz=timezone.utc),
                jti=str(claims["j"]),
                grant_id=claims.get("g"),
                grant_version=claims.get("gv"),
                single_use=bool(claims.get("su", False)),
                key_version=int(claims.get("kv", 0)),
            )
        except (KeyError, ValueError, TypeError):
            self._reject("malformed")

        now = self._now()
        if parsed.expires_at <= now:
            self._reject("expired")

        if parsed.tier is VisibilityTier.PRIVATE:
            # Frozen rule: a private URL is useless without the matching identity.
            if not caller_id or caller_id != parsed.subject:
                self._reject("subject_mismatch")
        return parsed

    @staticmethod
    def _reject(reason: str) -> None:
        media_platform_metrics.increment("signed_url_rejected")
        # One uniform 404: never reveal whether the object exists, expired or was tampered.
        raise AppError(
            code="MEDIA_SIGNED_URL_INVALID",
            message="媒体链接无效或已过期",
            status_code=404,
            fields=[],
        )


def token_fingerprint(token: str) -> str:
    """Short, non-reversible handle for logs. Never the token itself."""

    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]
