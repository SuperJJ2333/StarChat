from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class MatrixMessageContent(BaseModel):
    body: str = Field(..., min_length=1)
    msgtype: str = "m.text"
    format: str | None = None
    formatted_body: str | None = None


class MatrixPublishRequest(BaseModel):
    event_type: str = "generic"
    route_key: str | None = None
    room_id: str | None = None
    room_alias: str | None = None
    idempotency_key: str | None = None
    message: MatrixMessageContent
    metadata: dict[str, Any] = Field(default_factory=dict)


class MatrixPublishResponse(BaseModel):
    ok: bool = True
    deduplicated: bool = False
    room_target: str
    room_id: str
    event_id: str
    message: str = "published"


class AutoReplyRule(BaseModel):
    contains: str = Field(..., min_length=1)
    reply: str = Field(..., min_length=1)
    room_id: str | None = None
    enabled: bool = True

