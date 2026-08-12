from __future__ import annotations

import logging

from nio import MatrixRoom, RoomMessageText

from app.models import AutoReplyRule, MatrixMessageContent
from app.settings import Settings


class BotEventHandler:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._logger = logging.getLogger(__name__)
        self._auto_reply_disabled_rooms: set[str] = set()
        self._rules = [AutoReplyRule.model_validate(rule) for rule in settings.auto_reply_rules]

    async def handle_message(self, room: MatrixRoom, event: RoomMessageText, bot_client: "MatrixBotClient") -> None:
        body = (event.body or "").strip()
        if not body:
            return

        if body.startswith(self._settings.matrix_command_prefix):
            await self._handle_command(room, event, body, bot_client)
            return

        if room.room_id in self._auto_reply_disabled_rooms:
            return

        lowered_body = body.lower()
        for rule in self._rules:
            if not rule.enabled:
                continue
            if rule.room_id and rule.room_id != room.room_id:
                continue
            if rule.contains.lower() not in lowered_body:
                continue

            await bot_client.send_message(
                room.room_id,
                MatrixMessageContent(body=rule.reply),
            )
            self._logger.info("Auto-replied in room %s for sender %s", room.room_id, event.sender)
            return

    async def _handle_command(
        self,
        room: MatrixRoom,
        event: RoomMessageText,
        body: str,
        bot_client: "MatrixBotClient",
    ) -> None:
        content = body[len(self._settings.matrix_command_prefix):].strip()
        if not content:
            return

        parts = content.split()
        command = parts[0].lower()
        args = parts[1:]

        if command == "ping":
            await bot_client.send_message(room.room_id, MatrixMessageContent(body="pong"))
            return

        if command == "help":
            help_text = (
                "Available commands: !ping, !help, !announce-test, !lottery-test, "
                "!autoreply on|off|status"
            )
            await bot_client.send_message(room.room_id, MatrixMessageContent(body=help_text))
            return

        if command in {"announce-test", "lottery-test", "autoreply"} and not self._is_authorized(event.sender):
            await bot_client.send_message(
                room.room_id,
                MatrixMessageContent(body="You are not allowed to run this command."),
            )
            return

        if command == "announce-test":
            await bot_client.send_message(
                room.room_id,
                MatrixMessageContent(
                    body="[Announcement] Scheduled maintenance tonight at 20:00.",
                    format="org.matrix.custom.html",
                    formatted_body="<strong>[Announcement]</strong> Scheduled maintenance tonight at 20:00.",
                ),
            )
            return

        if command == "lottery-test":
            await bot_client.send_message(
                room.room_id,
                MatrixMessageContent(
                    body="[Lottery] Issue 20260607 has been published.",
                    format="org.matrix.custom.html",
                    formatted_body="<strong>[Lottery]</strong> Issue 20260607 has been published.",
                ),
            )
            return

        if command == "autoreply":
            action = args[0].lower() if args else "status"
            if action == "on":
                self._auto_reply_disabled_rooms.discard(room.room_id)
                reply = "Auto-reply enabled for this room."
            elif action == "off":
                self._auto_reply_disabled_rooms.add(room.room_id)
                reply = "Auto-reply disabled for this room."
            else:
                enabled = room.room_id not in self._auto_reply_disabled_rooms
                reply = f"Auto-reply is {'enabled' if enabled else 'disabled'} for this room."

            await bot_client.send_message(room.room_id, MatrixMessageContent(body=reply))
            return

        await bot_client.send_message(
            room.room_id,
            MatrixMessageContent(body=f"Unknown command: {command}. Try !help."),
        )

    def _is_authorized(self, sender: str) -> bool:
        if not self._settings.admin_users:
            return True
        return sender in self._settings.admin_users


from app.matrix_client import MatrixBotClient  # noqa: E402

