from base64 import urlsafe_b64encode
from hashlib import sha256
from pathlib import Path
from typing import Protocol
from urllib.parse import quote, unquote

from cryptography.fernet import Fernet, InvalidToken

from app.core.errors import AppError


class PrivateObjectStorage(Protocol):
    def put(self, object_key: str, content: bytes) -> None: ...

    def get(self, object_key: str) -> bytes: ...

    def delete(self, object_key: str) -> None: ...

    def signed_read_url(self, object_key: str, expires_in: int) -> str: ...

    def resign_read_url(self, token: str, expires_in: int) -> str:
        """解出既有签名令牌内的对象键并按新 TTL 重新签发（救活过期链接）。"""
        ...


class LocalPrivateObjectStorage:
    def __init__(self, *, root: str, signing_secret: str, public_base_url: str) -> None:
        if len(signing_secret) < 16:
            raise ValueError("avatar signing secret must be at least 16 characters")
        self._root = Path(root).resolve()
        key = urlsafe_b64encode(sha256(signing_secret.encode("utf-8")).digest())
        self._fernet = Fernet(key)
        self._public_base_url = public_base_url.rstrip("/")

    def put(self, object_key: str, content: bytes) -> None:
        target = self._path(object_key)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_bytes(content)
        temporary.replace(target)

    def get(self, object_key: str) -> bytes:
        try:
            return self._path(object_key).read_bytes()
        except FileNotFoundError:
            raise AppError(
                code="AVATAR_NOT_FOUND",
                message="头像不存在",
                status_code=404,
            ) from None

    def delete(self, object_key: str) -> None:
        self._path(object_key).unlink(missing_ok=True)

    def signed_read_url(self, object_key: str, expires_in: int) -> str:
        token = self.sign_key(object_key)
        return (
            f"{self._public_base_url}/api/v1/profile/avatar/content/"
            f"{quote(token, safe='')}?expires_in={expires_in}"
        )

    def sign_key(self, object_key: str) -> str:
        """签出可回读对象键的令牌（供业务域媒体构造自有读取路径）。"""
        return self._fernet.encrypt(object_key.encode("utf-8")).decode("ascii")

    allowed_read_ttls = (300, 604800)

    def resign_read_url(self, token: str, expires_in: int) -> str:
        token = unquote(token)
        object_key = self._fernet.decrypt(token.encode("ascii")).decode("utf-8")
        return self.signed_read_url(object_key, expires_in)

    def read_signed(self, token: str, expires_in: int) -> tuple[bytes, str]:
        if expires_in not in self.allowed_read_ttls:
            self._invalid_signed_url()
        try:
            object_key = self._fernet.decrypt(
                token.encode("ascii"),
                ttl=expires_in,
            ).decode("utf-8")
        except (InvalidToken, UnicodeError):
            self._invalid_signed_url()
        mime_type = {
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".png": "image/png",
            ".webp": "image/webp",
            ".gif": "image/gif",
        }.get(Path(object_key).suffix.casefold())
        if mime_type is None:
            self._invalid_signed_url()
        return self.get(object_key), mime_type

    def _path(self, object_key: str) -> Path:
        candidate = (self._root / object_key).resolve()
        if candidate == self._root or self._root not in candidate.parents:
            raise AppError(
                code="AVATAR_STORAGE_KEY_INVALID",
                message="头像存储引用无效",
                status_code=500,
            )
        return candidate

    @staticmethod
    def _invalid_signed_url() -> None:
        raise AppError(
            code="AVATAR_URL_INVALID",
            message="头像链接无效或已过期",
            status_code=404,
        )
