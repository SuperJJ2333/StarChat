from pathlib import Path

from app.core.errors import AppError


class LocalPrivateAvatarReader:
    def __init__(self, root: str, *, backend=None) -> None:
        self._root = Path(root).resolve()
        self._backend = backend

    def delete(self, object_key: str) -> None:
        if self._backend is not None:
            self._backend.delete(object_key)
            return
        candidate = (self._root / object_key).resolve()
        if candidate == self._root or self._root not in candidate.parents:
            raise AppError(code="AVATAR_STORAGE_KEY_INVALID",
                message="avatar storage key is invalid", status_code=500)
        candidate.unlink(missing_ok=True)

    def get(self, object_key: str) -> bytes:
        if self._backend is not None:
            try:
                return self._backend.get(object_key)
            except AppError as error:
                if error.code != 'MEDIA_BLOB_MISSING':
                    raise
                raise AppError(code='AVATAR_NOT_FOUND', message='avatar object not found', status_code=404) from None
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
