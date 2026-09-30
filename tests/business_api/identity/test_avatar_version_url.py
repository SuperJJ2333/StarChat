from hashlib import sha256
from urllib.parse import parse_qs, urlsplit

from app.integrations.private_storage import LocalPrivateObjectStorage


def test_avatar_version_is_stable_across_resigning_and_changes_with_object(tmp_path):
    storage = LocalPrivateObjectStorage(
        root=str(tmp_path),
        signing_secret="unit-test-secret-at-least-16-characters",
        public_base_url="https://media.example.test",
    )
    key = "avatars/user-test/upload-one.png"
    expected = sha256(key.encode("utf-8")).hexdigest()[:32]

    first = storage.signed_read_url(key, 300)
    second = storage.signed_read_url(key, 300)
    replaced = storage.signed_read_url("avatars/user-test/upload-two.png", 300)
    poster = storage.signed_read_url("moments/covers/poster.png", 300)

    first_parts, second_parts, replacement_parts = map(
        urlsplit, (first, second, replaced)
    )
    assert first_parts.path != second_parts.path
    assert parse_qs(first_parts.query)["v"] == [expected]
    assert parse_qs(second_parts.query)["v"] == [expected]
    assert parse_qs(replacement_parts.query)["v"] != [expected]
    assert parse_qs(first_parts.query)["expires_in"] == ["300"]
    assert "v" not in parse_qs(urlsplit(poster).query)
    assert "avatars/user-test" not in first
