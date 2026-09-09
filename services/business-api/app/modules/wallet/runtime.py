"""Explicit production adapters; disabled mode creates no fallback provider."""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal

from app.integrations.tron.finality import POLICY, TronGridFinality, MANUAL_SOLID_HEAD_MAX_AGE_SECONDS
from app.modules.identity.totp import FernetSecretProtector, TotpService
from app.modules.wallet.binding import WalletBindingService
from app.modules.wallet.binding_adapters import TronBindingVerifier, WalletTotpVerifier
from app.modules.wallet.funding import DepositIntentService, OfficialFundingConfig
from app.modules.wallet.manual_payouts import ManualPayoutPolicy, ManualPayoutService
from app.modules.wallet.receipts import DepositReceiptService


@dataclass
class ManualWalletRuntime:
    binding: WalletBindingService
    intents: DepositIntentService
    receipts: DepositReceiptService
    payouts: ManualPayoutService
    finality: TronGridFinality
    funds_enabled: bool
    deposit_gate: bool | None = None
    payout_request_gate: bool | None = None
    payout_execution_gate: bool | None = None
    conversions_enabled: bool = False

    @property
    def deposits_enabled(self):
        return self.funds_enabled if self.deposit_gate is None else self.deposit_gate

    @property
    def payout_requests_enabled(self):
        return self.funds_enabled if self.payout_request_gate is None else self.payout_request_gate

    @property
    def payout_execution_enabled(self):
        return self.funds_enabled if self.payout_execution_gate is None else self.payout_execution_gate

    def close(self):
        self.finality.close()


def create_manual_wallet_runtime(settings, factory, rate_limiter):
    if settings.wallet_real_mode == 'disabled':
        return None
    clock = lambda: datetime.now(timezone.utc)
    finality = TronGridFinality(base_url='https://api.trongrid.io', clock=clock, max_age_seconds=120,
        solid_head_max_age_seconds=MANUAL_SOLID_HEAD_MAX_AGE_SECONDS,
        api_key=settings.wallet_trongrid_api_key.get_secret_value() if settings.wallet_trongrid_api_key else None)
    try:
        totp = TotpService(factory, protector=FernetSecretProtector(settings.wallet_totp_encryption_key.get_secret_value().encode('ascii')))
        mfa = WalletTotpVerifier(totp, rate_limiter, clock=clock)
        verifier = TronBindingVerifier(finality)
        binding = WalletBindingService(factory, domain=settings.wallet_binding_domain,
            mfa_verifier=mfa, permission_verifier=verifier.permission, barrier_verifier=verifier.barrier,
            clock=clock, finality_policy=POLICY)
        official = OfficialFundingConfig(settings.wallet_official_address.get_secret_value(), settings.wallet_official_config_version)
        intents = DepositIntentService(factory, official_config=official,
            intent_ttl=timedelta(seconds=settings.wallet_deposit_intent_ttl_seconds), clock=clock)
        receipts = DepositReceiptService(factory, finality_adapter=finality, official_config=official,
            activation_baseline_time=settings.wallet_funding_baseline_at,
            activation_baseline_height=settings.wallet_funding_baseline_height, clock=clock)
        payouts = ManualPayoutService(factory, official_config=official,
            policy=ManualPayoutPolicy(settings.wallet_manual_policy_version, timedelta(seconds=settings.wallet_manual_quote_ttl_seconds),
                Decimal(settings.wallet_manual_max_per), Decimal(settings.wallet_manual_user_24h), Decimal(settings.wallet_manual_global_24h)),
            owner_admin_id=settings.wallet_manual_owner_admin_id, mfa_verifier=mfa, finality=finality, clock=clock)
        receipts.reserve_policy = settings.wallet_reserve_policy
        receipts.wallet_ledger.reserve_policy = settings.wallet_reserve_policy
        payouts.reserve_policy = settings.wallet_reserve_policy
        if settings.wallet_user_auth_mode == 'address_only':
            binding.address_registration_enabled = True
            binding.barrier_verifier = verifier.registration_barrier
            payouts.user_mfa_required = False
        return ManualWalletRuntime(binding, intents, receipts, payouts, finality, settings.wallet_real_funds_enabled,
            settings.wallet_deposits_enabled, settings.wallet_payout_requests_enabled,
            settings.wallet_payout_execution_enabled, settings.wallet_conversions_enabled)
    except Exception:
        finality.close()
        raise
