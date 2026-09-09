"""Server adapters; authenticated routes supply identity, never verification flags."""
from datetime import datetime, timezone
import hashlib
import re

from app.core.errors import AppError
from app.integrations.tron.finality import AccountControlEvidence, NETWORK, POLICY, SOURCE_ID, TronEvidenceUnavailable
from app.modules.wallet.binding import VerifiedBindingBarrier


class TronBindingVerifier:
    def __init__(self, finality):
        self.finality = finality

    def _control(self, address):
        evidence = self.finality.account_control(address)
        if (not isinstance(evidence, AccountControlEvidence) or evidence.address != address
                or evidence.network != NETWORK or evidence.policy != POLICY or evidence.source_id != SOURCE_ID
                or evidence.solid_head.policy != POLICY or evidence.solid_head.source_id != SOURCE_ID):
            raise TronEvidenceUnavailable('TRON account control evidence mismatch')
        return evidence

    def permission(self, *, address, network, now):
        if network != NETWORK:
            return False
        try:
            self._control(address)
        except TronEvidenceUnavailable:
            return False
        return True

    def barrier(self, *, binding, now):
        try:
            evidence = self._control(binding.address)
        except TronEvidenceUnavailable:
            raise AppError(code='WALLET_BINDING_BARRIER_UNAVAILABLE',
                message='钱包链上核验暂不可用', status_code=503) from None
        head = evidence.solid_head
        return VerifiedBindingBarrier(height=head.height, block_id=head.block_id, network=evidence.network,
            source_ids=(evidence.source_id,), binding_id=binding.id,
            observed_at=evidence.observed_at, policy=evidence.policy)

    def registration_barrier(self, *, binding, now):
        """Establish activation height only; makes no account-control claim."""
        try:
            head = self.finality.solid_head()
        except TronEvidenceUnavailable:
            raise AppError(code='WALLET_BINDING_BARRIER_UNAVAILABLE',
                message='链上同步暂不可用，请稍后刷新', status_code=503) from None
        return VerifiedBindingBarrier(height=head.height, block_id=head.block_id,
            network=head.network, source_ids=(head.source_id,), binding_id=binding.id,
            observed_at=head.observed_at, policy=head.policy)


class WalletTotpVerifier:
    """Reuses the identity domain's one-time verifier; no client timestamp accepted."""
    def __init__(self, totp, rate_limiter, *, clock):
        self.totp, self.rate_limiter, self.clock = totp, rate_limiter, clock

    def __call__(self, *, user_id, session_id, proof, now):
        if not user_id or not session_id:
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        key = 'wallet-mfa:' + hashlib.sha256(user_id.encode()).hexdigest()
        self.rate_limiter.hit(key, limit=5, window_seconds=300)
        if not isinstance(proof, str) or re.fullmatch(r'[0-9]{6}', proof) is None:
            raise AppError(code='TOTP_INVALID', message='动态验证码无效', status_code=401)
        verified_at = self.totp.verify(user_id, proof)
        checked_at = self.clock()
        if (not isinstance(verified_at, datetime) or verified_at.tzinfo is None or verified_at.utcoffset() is None
                or not isinstance(checked_at, datetime) or checked_at.tzinfo is None or checked_at.utcoffset() is None
                or not 0 <= (checked_at.astimezone(timezone.utc) - verified_at.astimezone(timezone.utc)).total_seconds() <= 30):
            raise AppError(code='TOTP_REQUIRED', message='需要重新验证动态验证码', status_code=403)
        return True
