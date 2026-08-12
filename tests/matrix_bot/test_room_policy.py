from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.matrix_client import MatrixBotClient
from app.models import MatrixMessageContent
from app.room_policy import RoomAccessPolicy, RoomTargetNotAllowed
from app.settings import Settings


def test_allowed_room_can_be_used() -> None:
    policy = RoomAccessPolicy({"!system:example.test", "#notice:example.test"})

    policy.require_allowed("!system:example.test")


def test_unknown_room_is_rejected() -> None:
    policy = RoomAccessPolicy({"!system:example.test"})

    with pytest.raises(RoomTargetNotAllowed):
        policy.require_allowed("!private:example.test")


def test_empty_allowlist_denies_every_room() -> None:
    policy = RoomAccessPolicy(set())

    assert not policy.is_allowed("!any:example.test")


def test_settings_parse_allowed_room_targets() -> None:
    settings = Settings(
        MATRIX_HOMESERVER_URL="https://matrix.example.test/",
        MATRIX_BOT_USER_ID="@notification:example.test",
        MATRIX_BOT_PASSWORD="test-password",
        MATRIX_INTERNAL_API_KEY="test-key",
        MATRIX_ALLOWED_ROOM_TARGETS_JSON='["!system:example.test", "#notice:example.test"]',
    )

    assert settings.allowed_room_targets == {
        "!system:example.test",
        "#notice:example.test",
    }


@pytest.mark.asyncio
async def test_send_rejects_unauthorized_room_before_matrix_access() -> None:
    settings = SimpleNamespace(allowed_room_targets={"!system:example.test"})
    bot_client = MatrixBotClient(settings)
    bot_client._client = object()  # type: ignore[assignment]

    with pytest.raises(RoomTargetNotAllowed):
        await bot_client.send_message(
            "!private:example.test",
            MatrixMessageContent(body="notification"),
        )


@pytest.mark.asyncio
async def test_unknown_room_invitation_is_not_joined() -> None:
    settings = SimpleNamespace(allowed_room_targets={"!system:example.test"})
    bot_client = MatrixBotClient(settings)
    matrix_client = AsyncMock()
    bot_client._client = matrix_client

    await bot_client._on_invite(  # type: ignore[arg-type]
        SimpleNamespace(room_id="!private:example.test"),
        SimpleNamespace(sender="@attacker:example.test"),
    )

    matrix_client.join.assert_not_awaited()


@pytest.mark.asyncio
async def test_allowed_room_invitation_is_joined() -> None:
    settings = SimpleNamespace(allowed_room_targets={"!system:example.test"})
    bot_client = MatrixBotClient(settings)
    matrix_client = AsyncMock()
    bot_client._client = matrix_client

    await bot_client._on_invite(  # type: ignore[arg-type]
        SimpleNamespace(room_id="!system:example.test"),
        SimpleNamespace(sender="@admin:example.test"),
    )

    matrix_client.join.assert_awaited_once_with("!system:example.test")
