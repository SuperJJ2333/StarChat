"""Keep the deployed Worker avatar backend contract during admin integration."""

import pytest

from app.core.errors import AppError
from app.modules.media.storage import LocalBlobBackend
from integrations.avatar_reader import LocalPrivateAvatarReader


def test_worker_avatar_reader_uses_the_configured_media_backend(tmp_path):
    backend = LocalBlobBackend(root=str(tmp_path))
    backend.put("avatars/user/photo.png", b"private avatar")
    reader = LocalPrivateAvatarReader(str(tmp_path), backend=backend)

    assert reader.get("avatars/user/photo.png") == b"private avatar"
    reader.delete("avatars/user/photo.png")
    with pytest.raises(AppError) as error:
        reader.get("avatars/user/photo.png")
    assert error.value.code == "AVATAR_NOT_FOUND"
