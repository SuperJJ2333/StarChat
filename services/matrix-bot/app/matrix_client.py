from __future__ import annotations

import asyncio
import contextlib
import logging
from pathlib import Path
from typing import Awaitable, Callable

from nio import AsyncClient, AsyncClientConfig, InviteMemberEvent, MatrixRoom, RoomMessageText

from app.models import MatrixMessageContent
from app.room_policy import RoomAccessPolicy
from app.settings import Settings

MessageCallback = Callable[[MatrixRoom, RoomMessageText, "MatrixBotClient"], Awaitable[None]]


class MatrixBotClient:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._logger = logging.getLogger(__name__)
        self._client: AsyncClient | None = None
        self._sync_task: asyncio.Task[None] | None = None
        self._message_callback: MessageCallback | None = None
        self._started = False
        self._room_access_policy = RoomAccessPolicy(settings.allowed_room_targets)

    @property
    def is_ready(self) -> bool:
        return self._started and self._client is not None

    def set_message_callback(self, callback: MessageCallback) -> None:
        self._message_callback = callback

    async def start(self) -> None:
        Path(self._settings.matrix_bot_store_path).mkdir(parents=True, exist_ok=True)

        config = AsyncClientConfig(
            store_sync_tokens=True,
            encryption_enabled=True,
        )
        self._client = AsyncClient(
            self._settings.matrix_homeserver_url,
            self._settings.matrix_bot_user_id,
            device_id=self._settings.matrix_bot_device_id,
            store_path=self._settings.matrix_bot_store_path,
            config=config,
        )
        self._client.add_event_callback(self._on_message, RoomMessageText)
        self._client.add_event_callback(self._on_invite, InviteMemberEvent)

        if self._settings.matrix_bot_access_token:
            self._client.restore_login(
                user_id=self._settings.matrix_bot_user_id,
                device_id=self._settings.matrix_bot_device_id or "",
                access_token=self._settings.matrix_bot_access_token,
            )
            self._logger.info("Restored Matrix bot session for %s", self._settings.matrix_bot_user_id)
        else:
            response = await self._client.login(self._settings.matrix_bot_password or "", device_name="StarChat Matrix Bot")
            if not hasattr(response, "access_token"):
                raise RuntimeError(f"Matrix bot login failed: {response}")
            self._logger.info("Logged in Matrix bot as %s", self._settings.matrix_bot_user_id)

        self._sync_task = asyncio.create_task(self._sync_forever(), name="matrix-sync")
        self._started = True

    async def stop(self) -> None:
        self._started = False
        if self._sync_task is not None:
            self._sync_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._sync_task
        if self._client is not None:
            await self._client.close()

    async def send_message(self, room_target: str, message: MatrixMessageContent) -> tuple[str, str]:
        self._room_access_policy.require_allowed(room_target)

        if self._client is None:
            raise RuntimeError("Matrix bot client has not started.")

        room_id = await self._resolve_room_target(room_target)
        join_target = room_target if room_target.startswith("#") else room_id
        await self._ensure_joined(join_target, room_id)

        content = {
            "msgtype": message.msgtype,
            "body": message.body,
        }
        if message.formatted_body:
            content["format"] = message.format or "org.matrix.custom.html"
            content["formatted_body"] = message.formatted_body

        response = await self._client.room_send(
            room_id=room_id,
            message_type="m.room.message",
            content=content,
            ignore_unverified_devices=self._settings.matrix_allow_unverified_devices,
        )
        event_id = getattr(response, "event_id", None)
        if not event_id:
            raise RuntimeError(f"Matrix message send failed: {response}")

        return event_id, room_id

    async def _sync_forever(self) -> None:
        if self._client is None:
            return
        await self._client.sync_forever(
            timeout=self._settings.matrix_sync_timeout_ms,
            full_state=self._settings.matrix_sync_full_state,
            set_presence="online",
        )

    async def _resolve_room_target(self, room_target: str) -> str:
        if self._client is None:
            raise RuntimeError("Matrix bot client has not started.")

        if room_target.startswith("!"):
            return room_target

        response = await self._client.room_resolve_alias(room_target)
        room_id = getattr(response, "room_id", None)
        if not room_id:
            raise RuntimeError(f"Failed to resolve room target {room_target}: {response}")
        return room_id

    async def _ensure_joined(self, join_target: str, room_id: str) -> None:
        if self._client is None:
            raise RuntimeError("Matrix bot client has not started.")

        if room_id in self._client.rooms:
            return

        response = await self._client.join(join_target)
        joined_room_id = getattr(response, "room_id", None)
        if not joined_room_id:
            self._logger.warning("Bot failed to auto-join %s: %s", join_target, response)

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent) -> None:
        if self._client is None:
            return
        if not self._room_access_policy.is_allowed(room.room_id):
            self._logger.warning("Ignored invite to unauthorized room %s from %s", room.room_id, event.sender)
            return
        self._logger.info("Received invite to room %s from %s", room.room_id, event.sender)
        await self._client.join(room.room_id)

    async def _on_message(self, room: MatrixRoom, event: RoomMessageText) -> None:
        if event.sender == self._settings.matrix_bot_user_id:
            return

        if self._message_callback is not None:
            await self._message_callback(room, event, self)
