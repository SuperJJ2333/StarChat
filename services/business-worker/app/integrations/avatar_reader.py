from pathlib import Path

from app.core.errors import AppError


class LocalPrivateAvatarReader:
    def __init__(self, root: str) -> None:
        self._root = Path(root).resolve()

    def get(self, object_key: str) -> bytes:
        candidate = (self._root / object_key).resolve()
        if candidate == self._root or self._root not in candidate.parents:
            raise AppError(
                code="AVATAR_STORAGE_KEY_INVALID",
                message="avatar storage key is invalid",
                status_code=500,
            )
        try:
            return candidate.read_bytes()
        except FileNotFoundError:
            raise AppError(
                code="AVATAR_NOT_FOUND",
                message="avatar object not found",
                status_code=404,
            ) from None
