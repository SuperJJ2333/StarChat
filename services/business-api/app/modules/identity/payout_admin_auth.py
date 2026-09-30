"""Live official-owner policy for administrative withdrawals only."""
from app.core.errors import AppError
from app.modules.identity.support_order_auth import SupportOrderSessionAuthorizer
from app.modules.identity.wallet_access import require_wallet_actor


class PayoutAdminSessionAuthorizer(SupportOrderSessionAuthorizer):
    def _identity(self, session, claims):
        fresh = super()._identity(session, claims)
        if claims['sub'] != self.settings.wallet_manual_owner_admin_id:
            raise AppError(code='PERMISSION_DENIED', message='仅官方钱包管理员可处理提现', status_code=403)
        require_wallet_actor(session, user_id=claims['sub'], clock=self.clock, administrator=True)
        return fresh
