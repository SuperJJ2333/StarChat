from app.core.errors import AppError
from app.modules.identity.profile import ProfileService


class AvatarCleanupTask:
    def __init__(self, session_factory, *, storage):
        self._profiles = ProfileService(session_factory, storage=storage)

    def __call__(self, message):
        payload = message.payload
        if (message.topic != "identity.avatar.cleanup"
                or message.event_type != "identity.avatar.retired"
                or message.aggregate_type != "avatar_cleanup"
                or not isinstance(payload, dict) or set(payload) != {"user_id", "object_key"}
                or not isinstance(payload["user_id"], str)
                or not isinstance(payload["object_key"], str) or message.headers != {}):
            raise AppError(code="AVATAR_CLEANUP_INVALID", message="头像清理任务无效", status_code=400)
        self._profiles.cleanup_retired_avatar(payload["user_id"], payload["object_key"])
