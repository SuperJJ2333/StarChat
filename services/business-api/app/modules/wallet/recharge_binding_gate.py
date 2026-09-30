"""Wallet-owned binding gate for new manual recharge requests."""

from sqlalchemy.orm import Session

from app.core.errors import AppError
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState


class WalletRechargeBindingGate:
    def require_active(self, session: Session, user_id: str) -> int:
        """Validate the binding inside the caller's transaction and return its version."""
        state = session.get(WalletBindingState, user_id, with_for_update=True,
                            populate_existing=True)
        if state is not None and state.pending_binding_id:
            raise AppError(code="WALLET_BINDING_PENDING", message="钱包绑定正在变更", status_code=409)
        if state is None or not state.active_binding_id:
            raise AppError(code="WALLET_BINDING_REQUIRED", message="请先绑定钱包地址", status_code=409)

        binding = session.get(WalletBinding, state.active_binding_id, populate_existing=True)
        if (binding is None or binding.user_id != user_id or binding.status != "ACTIVE"
                or binding.version != state.version or binding.effective_from_block is None
                or binding.effective_to_block is not None):
            raise AppError(code="WALLET_BINDING_VERSION_CONFLICT", message="钱包绑定状态已变化", status_code=409)
        return binding.version
