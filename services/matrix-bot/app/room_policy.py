from __future__ import annotations


class RoomTargetNotAllowed(ValueError):
    """Raised when the notification bot is asked to use an unauthorized room."""


class RoomAccessPolicy:
    def __init__(self, allowed_targets: set[str]) -> None:
        self._allowed_targets = frozenset(allowed_targets)

    def is_allowed(self, target: str) -> bool:
        return target in self._allowed_targets

    def require_allowed(self, target: str) -> None:
        if not self.is_allowed(target):
            raise RoomTargetNotAllowed(f"Matrix room target is not authorized: {target}")
