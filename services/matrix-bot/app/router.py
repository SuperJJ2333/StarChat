from __future__ import annotations

from dataclasses import dataclass

from app.models import MatrixPublishRequest


@dataclass(frozen=True)
class RoomTarget:
    value: str


class RoomRouter:
    def __init__(self, routes: dict[str, str], default_room_id: str | None) -> None:
        self._routes = routes
        self._default_room_id = default_room_id

    def resolve(self, request: MatrixPublishRequest) -> RoomTarget | None:
        if request.room_id:
            return RoomTarget(request.room_id)

        if request.room_alias:
            return RoomTarget(request.room_alias)

        if request.route_key and request.route_key in self._routes:
            return RoomTarget(self._routes[request.route_key])

        event_route = self._routes.get(f"event:{request.event_type}")
        if event_route:
            return RoomTarget(event_route)

        default_route = self._routes.get("default") or self._default_room_id
        if default_route:
            return RoomTarget(default_route)

        return None

