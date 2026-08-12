from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api import create_api_router
from app.handlers import BotEventHandler
from app.idempotency import IdempotencyStore
from app.matrix_client import MatrixBotClient
from app.router import RoomRouter
from app.settings import Settings


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )


settings = Settings()
configure_logging(settings.log_level)

room_router = RoomRouter(settings.room_routing, settings.matrix_default_room_id)
idempotency_store = IdempotencyStore(settings.matrix_idempotency_db_path, settings.matrix_message_dedup_ttl_seconds)
bot_client = MatrixBotClient(settings)
event_handler = BotEventHandler(settings)


@asynccontextmanager
async def lifespan(_: FastAPI):
    bot_client.set_message_callback(event_handler.handle_message)
    await bot_client.start()
    try:
        yield
    finally:
        await bot_client.stop()
        idempotency_store.close()


app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.include_router(create_api_router(settings, room_router, bot_client, idempotency_store))

