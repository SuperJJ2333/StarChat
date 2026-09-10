from datetime import datetime, timezone

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import AdminSession, MobileMatrixSession, RefreshTokenFamily, User


class MatrixSessionService:
    def __init__(self, session_factory, *, gateway):
        self._session_factory = session_factory
        self._gateway = gateway

    def bind(self, *, user_id, family_id, matrix_access_token, matrix_device_id):
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == user_id).with_for_update())
            family = session.get(RefreshTokenFamily, family_id)
            admin = session.get(AdminSession, user_id)
            if (user is None or user.status.value != 'ACTIVE' or family is None
                    or family.user_id != user_id or family.revoked_at is not None
                    or (admin is not None and admin.family_id == family_id)):
                raise AppError(code='SESSION_REPLACED', message='账号已在其他设备登录，请重新登录', status_code=401)
            current = session.get(MobileMatrixSession, user_id)
            if (current is None or current.family_id != family_id
                    or current.matrix_device_id != matrix_device_id):
                raise AppError(code='MATRIX_LOGIN_REQUIRED', message='请重新建立聊天登录', status_code=409)
            # Identity verification and upstream writes share the login user lock.
            matrix_user_id, verified_device = self._gateway.session_identity(matrix_access_token)
            if (not user.matrix_user_id or matrix_user_id != user.matrix_user_id
                    or not verified_device or verified_device != matrix_device_id):
                raise AppError(code='MATRIX_SESSION_IDENTITY_MISMATCH', message='聊天设备身份不匹配', status_code=403)
            current.updated_at = datetime.now(timezone.utc)
            AuditWriter(self._session_factory).record_in_session(session,
                actor_id=user_id, subject_type='user', subject_id=user_id,
                action='identity.matrix.session.bound', result='SUCCESS',
                reason_code='MOBILE_SINGLE_DEVICE', trace_id=family_id)
        return {'status': 'ACTIVE'}

    def revoke_from_outbox(self, message):
        payload = message.payload
        user_id = payload.get('user_id')
        device_id = payload.get('matrix_device_id')
        if (message.event_type != 'identity.matrix.device.revoke.requested'
                or message.aggregate_type != 'user' or message.aggregate_id != user_id
                or not isinstance(device_id, str) or not device_id or not user_id):
            raise AppError(code='MATRIX_EVENT_INVALID', message='无效聊天会话事件', status_code=400)
        # Retired before this topic was ever deployed. Native DELETE can outlive
        # an HTTP timeout and bypass the module generation lock. Only the broker
        # module may revoke sessions; acknowledge validated obsolete work safely.
        return
