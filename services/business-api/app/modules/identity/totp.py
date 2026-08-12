from base64 import b32encode
from dataclasses import dataclass
from datetime import datetime, timezone
import hmac
from hashlib import sha1
import secrets
from typing import Protocol
from uuid import uuid4

from cryptography.fernet import Fernet
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.models import TotpCredential


class SecretProtector(Protocol):
    def encrypt(self, plaintext: str) -> str: ...

    def decrypt(self, ciphertext: str) -> str: ...


class FernetSecretProtector:
    def __init__(self, key: bytes) -> None:
        self._fernet = Fernet(key)

    @classmethod
    def generate(cls) -> "FernetSecretProtector":
        return cls(Fernet.generate_key())

    def encrypt(self, plaintext: str) -> str:
        return self._fernet.encrypt(plaintext.encode()).decode()

    def decrypt(self, ciphertext: str) -> str:
        return self._fernet.decrypt(ciphertext.encode()).decode()


@dataclass(frozen=True)
class TotpEnrollment:
    credential_id: str
    secret: str


class TotpService:
    def __init__(self, session_factory, *, protector: SecretProtector, now_factory=None) -> None:
        self._session_factory = session_factory
        self._protector = protector
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def enroll(self, user_id: str) -> TotpEnrollment:
        now = self._now_factory()
        secret = b32encode(secrets.token_bytes(20)).decode().rstrip("=")
        credential = TotpCredential(
            id=str(uuid4()),
            user_id=user_id,
            encrypted_secret=self._protector.encrypt(secret),
            enabled=False,
            created_at=now,
        )
        with self._session_factory.begin() as session:
            existing = session.scalar(
                select(TotpCredential).where(TotpCredential.user_id == user_id)
            )
            if existing is not None:
                session.delete(existing)
                session.flush()
            session.add(credential)
        return TotpEnrollment(credential.id, secret)

    def enable(self, user_id: str, code: str) -> None:
        now = self._now_factory()
        with self._session_factory.begin() as session:
            credential = self._credential(session, user_id)
            secret = self._protector.decrypt(credential.encrypted_secret)
            if not self._matches(secret, code, now):
                self._invalid()
            credential.enabled = True

    def verify(self, user_id: str, code: str) -> datetime:
        now = self._now_factory()
        step = int(now.timestamp()) // 30
        with self._session_factory.begin() as session:
            credential = self._credential(session, user_id, lock=True)
            if not credential.enabled:
                self._required()
            if credential.last_accepted_step is not None and step <= credential.last_accepted_step:
                raise AppError(code="TOTP_REPLAYED", message="动态验证码已使用", status_code=401)
            secret = self._protector.decrypt(credential.encrypted_secret)
            if not self._matches(secret, code, now):
                self._invalid()
            credential.last_accepted_step = step
        return now

    def require_recent(
        self, user_id: str, *, verified_at: datetime | None, max_age_seconds: int
    ) -> None:
        if verified_at is None:
            self._required()
        now = self._now_factory()
        if verified_at.tzinfo is None:
            verified_at = verified_at.replace(tzinfo=timezone.utc)
        if (now - verified_at).total_seconds() > max_age_seconds:
            self._required()

    @staticmethod
    def code_at(secret: str, moment: datetime) -> str:
        step = int(moment.timestamp()) // 30
        key = secret + "=" * ((8 - len(secret) % 8) % 8)
        import base64

        digest = hmac.new(base64.b32decode(key), step.to_bytes(8, "big"), sha1).digest()
        offset = digest[-1] & 0x0F
        value = int.from_bytes(digest[offset : offset + 4], "big") & 0x7FFFFFFF
        return f"{value % 1_000_000:06d}"

    def _matches(self, secret: str, code: str, moment: datetime) -> bool:
        return hmac.compare_digest(self.code_at(secret, moment), code)

    @staticmethod
    def _credential(session, user_id: str, lock: bool = False) -> TotpCredential:
        statement = select(TotpCredential).where(TotpCredential.user_id == user_id)
        if lock:
            statement = statement.with_for_update()
        credential = session.scalar(statement)
        if credential is None:
            TotpService._required()
        return credential

    @staticmethod
    def _required() -> None:
        raise AppError(code="TOTP_REQUIRED", message="需要动态验证码", status_code=403)

    @staticmethod
    def _invalid() -> None:
        raise AppError(code="TOTP_INVALID", message="动态验证码无效", status_code=401)
