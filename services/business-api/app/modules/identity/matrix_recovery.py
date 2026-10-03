"""Current mobile authority only; recovery ciphertext never enters this domain."""
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.matrix_sessions import require_mobile_family
from app.modules.identity.models import MatrixLoginGeneration, MobileMatrixSession, User


class MatrixRecoveryAuthority:
    def __init__(self, session_factory):
        self._session_factory = session_factory

    def authorize(self, claims, *, matrix_user_id, matrix_device_id):
        if (claims.get('session_scope') not in (None, 'mobile')
                or not claims.get('family_id') or not claims.get('device_id')):
            raise AppError(code='MATRIX_RECOVERY_FORBIDDEN', message='需要当前移动端会话', status_code=403)
        # The same user lock as login/revocation defines this authority decision.
        with self._session_factory.begin() as session:
            user = session.scalar(select(User).where(User.id == claims['sub']).with_for_update())
            family = require_mobile_family(session, user, claims['family_id'])
            binding = session.get(MobileMatrixSession, user.id)
            generation = session.get(MatrixLoginGeneration, user.id)
            if (family.device_id != claims['device_id'] or user.matrix_user_id != matrix_user_id
                    or binding is None or binding.family_id != family.id
                    or binding.matrix_device_id != matrix_device_id
                    or generation is None or generation.generation < 1):
                raise AppError(code='MATRIX_RECOVERY_FORBIDDEN', message='聊天会话身份不匹配', status_code=403)
            return {'matrix_user_id': user.matrix_user_id, 'matrix_device_id': binding.matrix_device_id,
                    'family_id': family.id, 'generation': generation.generation}
