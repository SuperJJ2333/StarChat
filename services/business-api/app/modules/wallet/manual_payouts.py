"""Server-owned quotes and imToken operator workflow. This module never signs/broadcasts."""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext
from functools import wraps
import hashlib
import json
import re
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import object_session

from app.core.errors import AppError
from app.integrations.tron.finality import NETWORK, POLICY, SOURCE_ID, TransactionEvidence, TronEvidenceUnavailable, transaction_evidence_fresh
from app.integrations.tron.reader import USDT_CONTRACT
from app.integrations.tron.message_signature import canonical_address
from app.modules.identity.wallet_access import require_wallet_actor
from app.modules.identity.payment_pin import PaymentPinService
from app.modules.ledger.reserve import lock_budget
from app.modules.ledger.manual_payout_reserve import (
    require_manual_payout_coverage, mark_manual_payout_pending, finish_manual_payout_pending,
)
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState
from app.modules.wallet.models import WalletControl, WalletSafetyState, Withdrawal
from app.modules.wallet.safety import audit_write
from app.modules.wallet.service import WalletLedger
from app.modules.wallet.manual_payout_models import (
    ManualPayoutQuote, ManualPayoutOrder, ManualPayoutCommand, ManualPayoutEvent, ManualPayoutCandidate,
)
from app.modules.wallet.support_payout import SupportPayoutState, support_payout_projection


def _fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def has_pending_manual_payout(session, *, user_id):
    """Public binding guard; caller already holds reserve/control/binding locks."""
    return session.scalar(select(ManualPayoutOrder.id).where(ManualPayoutOrder.user_id == user_id,
        ManualPayoutOrder.status.in_(['REQUESTED', 'CLAIMED', 'UNKNOWN'])).limit(1)) is not None


def _precise(fn):
    @wraps(fn)
    def inner(*args, **kwargs):
        with localcontext() as context:
            context.prec = 50
            return fn(*args, **kwargs)
    return inner


@dataclass(frozen=True)
class ManualPayoutPolicy:
    version: str
    quote_ttl: timedelta
    max_per: Decimal
    user_24h: Decimal
    global_24h: Decimal

    def __post_init__(self):
        if not self.version or not isinstance(self.quote_ttl, timedelta) or not timedelta(0) < self.quote_ttl <= timedelta(hours=24):
            raise ValueError('explicit payout policy and bounded quote TTL required')
        for value in (self.max_per, self.user_24h, self.global_24h):
            if (not isinstance(value, Decimal) or not value.is_finite() or value < Decimal('10')
                    or value.as_tuple().exponent < -6 or value >= Decimal('1e24')):
                raise ValueError('explicit exact payout limits required')


class ManualPayoutService:
    user_mfa_required = True
    reserve_policy = 'full_backing'
    conversions_enabled = False
    support_orders_enabled = False
    def __init__(self, session_factory, *, official_config, policy, owner_admin_id, mfa_verifier, finality, clock, rate_provider=None):
        if not isinstance(policy, ManualPayoutPolicy) or not official_config.version:
            raise ValueError('explicit server policy required')
        canonical_address(official_config.address)
        if not callable(mfa_verifier) or not callable(clock):
            raise ValueError('server MFA and clock required')
        self.factory, self.official_config, self.policy = session_factory, official_config, policy
        if not isinstance(owner_admin_id, str) or not owner_admin_id.strip():
            raise ValueError('explicit official wallet owner administrator required')
        self.owner_admin_id = owner_admin_id
        self.mfa_verifier, self.finality, self.clock = mfa_verifier, finality, clock
        # ADR-0077：结算汇率提供者（返回 (rate, stale, fetched_at) 或 None）。
        # None = 未接汇率服务的历史装配（退回 1:1，仅测试/回退演练可用）；
        # 生产 runtime 必须注入，否则 CAIBI 报价 503。
        self.rate_provider = rate_provider
        self.wallet_ledger = WalletLedger(session_factory)
        self.payment_pin = PaymentPinService(session_factory, clock=clock)

    def _now(self):
        now = self.clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise ValueError('timezone-aware server clock required')
        return now.astimezone(timezone.utc)

    def _lock(self, session, user_id):
        reserve = lock_budget(session)
        control = session.get(WalletControl, 'global', with_for_update=True)
        if control is None:
            _fail('WALLET_CONTROL_UNAVAILABLE', 503)
        state = session.get(WalletBindingState, user_id, with_for_update=True)
        return reserve, control, state

    def _gate(self, session, user_id, now, locked, *, execution=False):
        reserve, control, state = locked
        require_wallet_actor(session, user_id=user_id, clock=self.clock)
        now = self._now()
        safety = session.get(WalletSafetyState, user_id)
        if safety and safety.restricted:
            _fail('WALLET_ACCOUNT_RESTRICTED', 403)
        if control.withdrawals_paused:
            _fail('WALLET_WITHDRAWALS_PAUSED')
        if state is None or not state.active_binding_id:
            _fail('WALLET_BINDING_REQUIRED')
        if state.pending_binding_id:
            _fail('WALLET_BINDING_PENDING')
        try:
            if execution or self.reserve_policy != 'manual_liquidity':
                require_manual_payout_coverage(session, reserve, now=now, policy=self.reserve_policy)
        except ValueError:
            _fail('WALLET_RESERVE_UNAVAILABLE', 503)
        binding = session.get(WalletBinding, state.active_binding_id)
        if binding is None or binding.status != 'ACTIVE' or binding.user_id != user_id:
            _fail('WALLET_BINDING_REQUIRED')
        return binding, safety.epoch if safety else 0

    def _mfa(self, user_id, session_id, proof, now):
        if not user_id or not session_id or self.mfa_verifier(user_id=user_id, session_id=session_id, proof=proof, now=now) is not True:
            _fail('WALLET_MFA_REQUIRED', 403)

    def _fresh_mfa(self, verified_at):
        if not 0 <= (self._now()-verified_at).total_seconds() <= 30:
            _fail('WALLET_MFA_EXPIRED', 403)

    def _replay(self, session, actor, operation, key, payload):
        if not isinstance(key, str) or not key.strip() or len(key) > 128:
            _fail('WALLET_IDEMPOTENCY_REQUIRED', 400)
        command = session.scalar(select(ManualPayoutCommand).where(ManualPayoutCommand.actor_id == actor,
            ManualPayoutCommand.operation == operation, ManualPayoutCommand.idempotency_key == key))
        if command:
            if command.digest != _digest(payload):
                _fail('WALLET_IDEMPOTENCY_CONFLICT')
            return command.response
        return None

    def recover(self, *, user_id, operation, idempotency_key, payload):
        """Existing quote/request response only; never authorize payment or take a hold."""
        allowed = {'QUOTE': ({'amount', 'binding_version'}, {'amount', 'binding_version', 'funding_asset'}),
            'REQUEST': ({'quote_id'},)}
        if operation not in allowed or not isinstance(payload, dict) or set(payload) not in allowed[operation]:
            _fail('WALLET_RECOVERY_OPERATION_INVALID', 400)
        with self.factory.begin() as session:
            self._lock(session, user_id)
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            return self._replay(session, user_id, operation, idempotency_key, payload)

    def _record(self, session, actor, operation, key, payload, response, now, *, reason_code=None):
        session.add(ManualPayoutCommand(id=str(uuid4()), actor_id=actor, operation=operation, idempotency_key=key,
            digest=_digest(payload), response=response, created_at=now))
        audit_write(session, actor, response['id'], 'wallet.manual_payout_' + operation.lower(), reason_code or 'MANUAL_PAYOUT_' + operation)
        session.flush()
        return response

    def _result(self, row):
        quote = object_session(row).get(ManualPayoutQuote, row.quote_id)
        terms = quote.snapshot
        asset = terms.get('funding_asset', 'USDT')
        settlement_txid = None
        if row.status == 'SETTLED':
            settlement_txid = object_session(row).scalar(select(ManualPayoutEvent.txid).where(ManualPayoutEvent.order_id == row.id))
        final_receive = row.final_receive if row.final_receive is not None else Decimal(terms.get('receive', str(row.amount)))
        return dict(id=row.id, user_id=row.user_id, quote_id=row.quote_id, amount=format(row.amount, '.6f'),
            status=row.status, digest=row.digest, candidate_txid=row.candidate_txid, review_reason=row.review_reason,
            settlement_txid=settlement_txid, funding_asset=asset,
            funding_amount=terms.get('funding_amount', format(row.amount, '.6f')),
            conversion_rate=terms.get('conversion_rate', '1'), rate_stale=bool(terms.get('rate_stale', False)),
            final_rate=format(row.final_rate, '.6f') if row.final_rate is not None else None,
            final_receive=format(final_receive, '.6f'),
            cancellation_asset=asset,
            **support_payout_projection(object_session(row),row,self._now()))

    def quote_status(self, *, user_id, quote_id):
        with self.factory.begin() as session:
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            quote = session.get(ManualPayoutQuote, quote_id)
            if quote is None or quote.user_id != user_id:
                _fail('WALLET_PAYOUT_QUOTE_NOT_FOUND', 404)
            return dict(quote.snapshot, id=quote.id, digest=quote.digest)

    @_precise
    def quote(self, *, user_id, amount, expected_binding_version, idempotency_key, funding_asset='USDT'):
        if (not isinstance(amount, str) or re.fullmatch(r'(0|[1-9][0-9]{0,23})\.[0-9]{6}', amount) is None
                or Decimal(amount) <= 0):
            _fail('WALLET_PAYOUT_AMOUNT_INVALID', 400)
        if funding_asset not in {'USDT', 'CAIBI'}:
            _fail('WALLET_PAYOUT_FUNDING_ASSET_INVALID', 400)
        if funding_asset == 'CAIBI' and Decimal(amount) != Decimal(amount).quantize(Decimal('0.01')):
            _fail('WALLET_PAYOUT_AMOUNT_INVALID', 400)
        if type(expected_binding_version) is not int:
            _fail('WALLET_BINDING_VERSION_CONFLICT')
        now = self._now()
        payload = dict(amount=amount, binding_version=expected_binding_version)
        if funding_asset != 'USDT':
            payload['funding_asset'] = funding_asset
        with self.factory.begin() as session:
            locked = self._lock(session, user_id)
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            replay = self._replay(session, user_id, 'QUOTE', idempotency_key, payload)
            if replay:
                return replay
            if funding_asset == 'CAIBI' and not self.conversions_enabled:
                _fail('WALLET_CONVERSION_DISABLED', 503)
            binding, epoch = self._gate(session, user_id, now, locked)
            now = self._now()
            if binding.version != expected_binding_version:
                _fail('WALLET_BINDING_VERSION_CONFLICT')
            if binding.address == self.official_config.address:
                _fail('WALLET_PAYOUT_OFFICIAL_TARGET_FORBIDDEN')
            # ADR-0077：点钻按 1 点钻=1 元人民币计价，USDT 应付 = 点钻 / 结算率。
            # 汇率快照进报价摘要（不可变）；stale 快照仅作参考并明确标注。
            rate, rate_stale, rate_fetched_at = Decimal('1'), False, None
            if funding_asset == 'CAIBI' and self.rate_provider is not None:
                provided = self.rate_provider()
                if provided is None:
                    _fail('WALLET_RATE_UNAVAILABLE', 503)
                rate, rate_stale, rate_fetched_at = provided
                if rate_stale or not rate.is_finite() or rate <= 0:
                    _fail('WALLET_RATE_UNAVAILABLE', 503)
            receive_amount = amount
            if funding_asset == 'CAIBI':
                receive_amount = format((Decimal(amount) / rate).quantize(Decimal('0.000001'), rounding='ROUND_HALF_UP'), '.6f')
            if Decimal(receive_amount) < Decimal('10') or Decimal(receive_amount) > self.policy.max_per:
                _fail('WALLET_PAYOUT_AMOUNT_INVALID', 400)
            snapshot = dict(binding_id=binding.id, binding_version=binding.version, target_address=binding.address,
                official_address=self.official_config.address, official_config_version=self.official_config.version,
                owner_admin_id=self.owner_admin_id,
                policy_version=self.policy.version, approval_policy='SUPPORT_MANUAL_V1' if self.support_orders_enabled else 'OWNER_MANUAL_V1', finality_policy=POLICY,
                network=NETWORK, contract=USDT_CONTRACT, amount=amount, fee='0.000000', hold=receive_amount, receive=receive_amount,
                minimum='10.000000', max_per=format(self.policy.max_per, '.6f'), user_24h=format(self.policy.user_24h, '.6f'),
                global_24h=format(self.policy.global_24h, '.6f'), safety_epoch=epoch, created_at=now.isoformat(),
                expires_at=(now+self.policy.quote_ttl).isoformat())
            snapshot.update(funding_asset=funding_asset,
                funding_amount=format(Decimal(amount), '.2f' if funding_asset == 'CAIBI' else '.6f'),
                conversion_rate=format(rate, '.6f'), conversion_fee='0.000000', cancellation_asset=funding_asset,
                rate_stale=rate_stale,
                **({'rate_fetched_at': rate_fetched_at} if rate_fetched_at else {}))
            row = ManualPayoutQuote(id=str(uuid4()), user_id=user_id, amount=Decimal(amount), snapshot=snapshot,
                digest=_digest(snapshot), created_at=now, expires_at=now+self.policy.quote_ttl)
            session.add(row)
            return self._record(session, user_id, 'QUOTE', idempotency_key, payload,
                dict(snapshot, id=row.id, digest=row.digest), now)

    def _limits(self, session, quote, now, *, effective=None, exclude_order_id=None):
        cutoff = now-timedelta(hours=24)
        orders = select(ManualPayoutOrder.user_id,
            func.coalesce(ManualPayoutOrder.final_receive, ManualPayoutOrder.amount)).where(
            ManualPayoutOrder.created_at > cutoff, ManualPayoutOrder.status != 'CANCELLED')
        if exclude_order_id is not None:
            orders = orders.where(ManualPayoutOrder.id != exclude_order_id)
        totals = list(session.execute(orders))
        totals += list(session.execute(select(Withdrawal.user_id, Withdrawal.amount).where(
            Withdrawal.created_at > cutoff, Withdrawal.status.notin_(['CANCELLED', 'FAILED_COMPENSATED']))))
        user_total = sum((a for uid, a in totals if uid == quote.user_id), Decimal('0'))
        total = sum((a for _, a in totals), Decimal('0'))
        # A tighter new server policy applies immediately, while older quoted caps remain ceilings.
        # ADR-0077：CAIBI 报价按 USDT 应付额计限额（风险口径始终是 USDT）。
        terms = quote.snapshot
        if effective is None:
            effective = Decimal(terms['receive']) if terms.get('funding_asset') == 'CAIBI' else quote.amount
        if (effective > min(self.policy.max_per, Decimal(terms['max_per']))
                or user_total+effective > min(self.policy.user_24h, Decimal(terms['user_24h']))
                or total+effective > min(self.policy.global_24h, Decimal(terms['global_24h']))):
            _fail('WALLET_PAYOUT_LIMIT_EXCEEDED')

    @_precise
    def request(self, *, user_id, session_id, mfa_proof, quote_id, idempotency_key,
                claims=None, payment_authorization=None):
        payload = dict(quote_id=quote_id)
        # Recovery must work with an expired quote/PIN/TOTP after acceptance.
        recovered = self.recover(user_id=user_id, operation='REQUEST',
            idempotency_key=idempotency_key, payload=payload)
        if recovered is not None:
            return recovered
        # A recovery probe must neither ask for nor burn one-time TOTP. Only a
        # genuinely authorized new attempt proceeds to the existing MFA check.
        if payment_authorization is None:
            _fail('PAYMENT_PIN_REQUIRED', 403)
        now = self._now()
        verified_at = now
        if self.user_mfa_required:
            self._mfa(user_id, session_id, mfa_proof, now)
        elif not user_id or not session_id:
            _fail('AUTH_REQUIRED', 401)
        now = self._now()
        with self.factory.begin() as session:
            locked = self._lock(session, user_id)
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            self._fresh_mfa(verified_at)
            replay = self._replay(session, user_id, 'REQUEST', idempotency_key, payload)
            if replay:
                return replay
            binding, epoch = self._gate(session, user_id, now, locked)
            now = self._now()
            self._fresh_mfa(verified_at)
            quote = session.get(ManualPayoutQuote, quote_id)
            if quote is None or quote.user_id != user_id:
                _fail('WALLET_PAYOUT_QUOTE_NOT_FOUND', 404)
            if now >= _utc(quote.expires_at):
                _fail('WALLET_PAYOUT_QUOTE_EXPIRED')
            terms = quote.snapshot
            if (terms['binding_id'] != binding.id or terms['binding_version'] != binding.version
                    or terms['safety_epoch'] != epoch or terms['official_config_version'] != self.official_config.version
                    or terms['official_address'] != self.official_config.address or terms['policy_version'] != self.policy.version
                    or terms['owner_admin_id'] != self.owner_admin_id
                    or quote.digest != _digest(terms)):
                _fail('WALLET_PAYOUT_QUOTE_CHANGED')
            if session.scalar(select(ManualPayoutOrder.id).where(ManualPayoutOrder.quote_id == quote_id)):
                _fail('WALLET_PAYOUT_QUOTE_USED')
            self._limits(session, quote, now)
            funding_asset = terms.get('funding_asset', 'USDT')
            if funding_asset == 'CAIBI' and terms.get('rate_stale', False):
                _fail('WALLET_RATE_UNAVAILABLE', 503)
            if funding_asset == 'CAIBI' and not self.conversions_enabled:
                _fail('WALLET_CONVERSION_DISABLED', 503)
            if funding_asset not in {'CAIBI', 'USDT'}:
                _fail('WALLET_PAYOUT_QUOTE_CHANGED')
            # Mandatory for all new withdrawals, independent of require_all.
            # The caller's transaction also owns all conversion/hold writes.
            self.payment_pin.consume(session, user_id=user_id, claims=claims,
                action='wallet.payout.create', payload=payload, idempotency_key=idempotency_key,
                authorization=payment_authorization, required=True)
            if claims['family_id'] != session_id:
                _fail('PAYMENT_AUTHORIZATION_INVALID', 403)
            # ADR-0077：订单金额 = 最终 USDT 应付（链上支付口径）；点钻
            # 报价单内 source 金额保存在 quote.snapshot.funding_amount。
            payout_usdt = Decimal(terms['receive']) if funding_asset == 'CAIBI' else quote.amount
            row = ManualPayoutOrder(id=str(uuid4()), quote_id=quote_id, user_id=user_id, amount=payout_usdt,
                digest=quote.digest, status='REQUESTED', created_at=now, updated_at=now)
            session.add(row)
            if terms.get('approval_policy') == 'SUPPORT_MANUAL_V1':
                session.add(SupportPayoutState(order_id=row.id,expires_at=now+timedelta(hours=2),version=0,review_required=False))
            if funding_asset == 'CAIBI':
                from decimal import ROUND_HALF_UP
                from app.modules.wallet.conversions import convert_for_payout
                caibi_amount = Decimal(terms['funding_amount'])
                rate = Decimal(terms['conversion_rate'])
                expected = (caibi_amount / rate).quantize(Decimal('0.000001'), rounding=ROUND_HALF_UP)
                if expected != payout_usdt:
                    _fail('WALLET_PAYOUT_QUOTE_CHANGED')
                convert_for_payout(session, self.factory, user_id=user_id,
                    caibi_amount=caibi_amount, usdt_amount=payout_usdt,
                    conversion_rate=rate, idempotency_key='payout:'+row.id,
                    reserve_policy=self.reserve_policy, now=now)
            self.wallet_ledger.post(entries={user_id: -row.amount, 'HOLD:'+user_id: row.amount}, actor_id=user_id,
                reason_code='MANUAL_PAYOUT_HOLD', idempotency_key=row.id, scope='wallet.manual_hold', session=session)
            return self._record(session, user_id, 'REQUEST', idempotency_key, payload, self._result(row), now)

    @staticmethod
    def _payable(row, quote) -> Decimal:
        """链上应付 USDT：汇率调整后取 final_receive，否则原报价 receive。"""
        if row.final_receive is not None:
            return row.final_receive
        return Decimal(quote.snapshot['receive'])

    @_precise
    def adjust_rate(self, *, admin_id, session_id, mfa_proof=None, order_id, new_rate, reason_code, idempotency_key, authorize=None):
        """ADR-0077 决策9：客服调整结算汇率（无需用户确认/复核/金额审批）。

        仅 CLAIMED 状态可调；记录处理人/时间/原因/前后值；冻结差额即时
        调平（HOLD 始终等于最终应付）；SETTLED/CANCELLED/UNKNOWN 不可调。
        """
        if not isinstance(reason_code, str) or len(reason_code.strip()) < 3:
            _fail('WALLET_PAYOUT_REASON_INVALID', 400)
        try:
            rate = Decimal(str(new_rate))
        except Exception:
            _fail('WALLET_RATE_INVALID', 400)
        if (not rate.is_finite() or not Decimal('0') < rate < Decimal('1000')
                or rate != rate.quantize(Decimal('0.000001'))):
            _fail('WALLET_RATE_INVALID', 400)
        verified_at = self._now()
        if authorize is None:
            self._mfa(admin_id, session_id, mfa_proof, verified_at)
        payload = dict(order_id=order_id, new_rate=format(rate, '.6f'), reason_code=reason_code)
        with self.factory.begin() as session:
            row, locked = self._order_lock(session, order_id)
            self._financial_actor(session,row,admin_id,authorize)
            fresh = authorize(session) if authorize is not None else lambda: self._fresh_mfa(verified_at)
            fresh()
            if row.claimed_by is None:
                _fail('WALLET_PAYOUT_RATE_ADJUST_UNAVAILABLE', 409)
            if row.claimed_by != admin_id:
                _fail('WALLET_PAYOUT_OWNER_REQUIRED', 403)
            replay = self._replay(session, admin_id, 'ADJUST_RATE', idempotency_key, payload)
            if replay:
                fresh()
                return replay
            if row.status != 'CLAIMED' or row.candidate_txid is not None:
                _fail('WALLET_PAYOUT_RATE_ADJUST_UNAVAILABLE', 409)
            require_wallet_actor(session, user_id=row.user_id, clock=self.clock)
            if locked[1].withdrawals_paused:
                _fail('WALLET_WITHDRAWALS_PAUSED')
            safety = session.get(WalletSafetyState, row.user_id)
            if safety and safety.restricted:
                _fail('WALLET_ACCOUNT_RESTRICTED', 403)
            if locked[0] is None or locked[0].outgoing_restricted:
                _fail('WALLET_RESERVE_UNAVAILABLE', 503)
            quote = session.get(ManualPayoutQuote, row.quote_id)
            if quote.snapshot.get('funding_asset', 'USDT') != 'CAIBI':
                _fail('WALLET_PAYOUT_RATE_ADJUST_UNAVAILABLE', 409)
            from decimal import ROUND_HALF_UP
            caibi_amount = Decimal(quote.snapshot['funding_amount'])
            new_receive = (caibi_amount / rate).quantize(Decimal('0.000001'), rounding=ROUND_HALF_UP)
            if new_receive < Decimal('10') or new_receive > self.policy.max_per:
                _fail('WALLET_PAYOUT_AMOUNT_INVALID', 400)
            self._limits(session, quote, self._now(), effective=new_receive, exclude_order_id=row.id)
            old_receive = self._payable(row, quote)
            delta = new_receive - old_receive
            if delta > 0 and locked[0].eligible_usdt < new_receive:
                _fail('WALLET_PAYMENT_LIQUIDITY_INSUFFICIENT')
            # Only move existing user funds into/out of HOLD. No platform issuance
            # or coverage bypass; WalletLedger serializes and verifies the debit.
            if delta:
                operation_key = _digest(dict(actor=admin_id, order_id=row.id, key=idempotency_key))
                try:
                    self.wallet_ledger.post(entries={row.user_id: -delta, 'HOLD:'+row.user_id: delta},
                        actor_id=admin_id, reason_code='MANUAL_PAYOUT_RATE_ADJUSTED',
                        idempotency_key='adj-hold:'+operation_key, scope='wallet.manual_hold_adjust', session=session)
                except ValueError as exc:
                    if str(exc) == 'insufficient USDT balance':
                        _fail('WALLET_PAYOUT_INSUFFICIENT_BALANCE')
                    raise
            history = list(row.adjustment_history or [])
            history.append(dict(actor_id=admin_id, at=self._now().isoformat(), reason_code=reason_code[:100],
                old_rate=format(row.final_rate, '.6f') if row.final_rate is not None else quote.snapshot.get('conversion_rate'),
                new_rate=format(rate, '.6f'),
                old_receive=format(old_receive, '.6f'), new_receive=format(new_receive, '.6f')))
            row.final_rate = rate
            row.final_receive = new_receive
            row.adjustment_history = history
            row.adjusted_digest = _digest(dict(quote.snapshot, receive=format(new_receive, '.6f'),
                conversion_rate=format(rate, '.6f'), adjusted=True))
            row.updated_at = self._now()
            result = self._record(session, admin_id, 'ADJUST_RATE', idempotency_key, payload, self._result(row), self._now(),
                reason_code='MANUAL_PAYOUT_RATE_ADJUSTED')
            fresh()
            return result

    def _order_lock(self, session, order_id):
        # Read identity only, then acquire the shared lock order before row locking.
        uid = session.scalar(select(ManualPayoutOrder.user_id).where(ManualPayoutOrder.id == order_id))
        if uid is None:
            _fail('WALLET_PAYOUT_NOT_FOUND', 404)
        locked = self._lock(session, uid)
        return session.get(ManualPayoutOrder, order_id, with_for_update=True), locked

    def _financial_actor(self, session, row, admin_id, authorize):
        quote=session.get(ManualPayoutQuote,row.quote_id)
        if quote.snapshot.get('approval_policy') == 'SUPPORT_MANUAL_V1':
            from app.modules.wallet.support_payout import _PayoutAuthorization
            if (not isinstance(authorize,_PayoutAuthorization) or authorize.order_id!=row.id
                    or authorize.claims.get('sub')!=admin_id):
                _fail('SUPPORT_PAYOUT_AUTHORIZATION_REQUIRED',403)
            require_wallet_actor(session,user_id=admin_id,clock=self.clock)
        else:
            require_wallet_actor(session,user_id=admin_id,clock=self.clock,administrator=True)

    def payment_instructions(self, *, admin_id, order_id, expected_digest, authorize):
        with self.factory.begin() as session:
            row,_=self._order_lock(session,order_id)
            self._financial_actor(session,row,admin_id,authorize)
            fresh=authorize(session)
            if row.status!='CLAIMED' or row.claimed_by!=admin_id:
                _fail('WALLET_PAYOUT_CLAIM_UNAVAILABLE')
            if expected_digest not in (row.digest,row.adjusted_digest):
                _fail('WALLET_PAYOUT_DIGEST_CONFLICT')
            result=self._claim_result(row,session.get(ManualPayoutQuote,row.quote_id))
            fresh()
            return result

    @_precise
    def cancel(self, *, user_id, order_id, idempotency_key):
        now = self._now()
        payload = dict(order_id=order_id)
        with self.factory.begin() as session:
            row, locked = self._order_lock(session, order_id)
            if row.user_id != user_id:
                _fail('WALLET_PAYOUT_NOT_FOUND', 404)
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            replay = self._replay(session, user_id, 'CANCEL', idempotency_key, payload)
            if replay:
                return replay
            if row.status != 'REQUESTED':
                _fail('WALLET_PAYOUT_CANNOT_CANCEL')
            support_state=session.get(SupportPayoutState,row.id,with_for_update=True)
            if support_state is not None and support_state.execution_started_at is not None:
                _fail('WALLET_PAYOUT_CANNOT_CANCEL')
            self.wallet_ledger.post(entries={'HOLD:'+user_id: -row.amount, user_id: row.amount}, actor_id=user_id,
                reason_code='MANUAL_PAYOUT_CANCELLED', idempotency_key=row.id, scope='wallet.manual_release', session=session)
            quote = session.get(ManualPayoutQuote, row.quote_id)
            if quote.snapshot.get('funding_asset', 'USDT') == 'CAIBI':
                from app.modules.wallet.conversions import reverse_payout_conversion
                reverse_payout_conversion(session, self.factory, user_id=user_id, order_id=row.id, amount=row.amount)
            row.status, row.updated_at = 'CANCELLED', now
            return self._record(session, user_id, 'CANCEL', idempotency_key, payload, self._result(row), now)

    def _claim_result(self, row, quote):
        return dict(self._result(row), instructions=dict(target_address=quote.snapshot['target_address'],
            official_address=quote.snapshot['official_address'], amount=format(self._payable(row, quote), '.6f'),
            network=NETWORK, contract=USDT_CONTRACT, digest=row.adjusted_digest or row.digest,
            warning='VERIFY_EXISTING_PAYMENT_BEFORE_SIGNING'))

    @_precise
    def claim(self, *, admin_id, session_id, mfa_proof=None, order_id, expected_digest, idempotency_key, authorize=None):
        now = self._now()
        verified_at = now
        if authorize is None:
            self._mfa(admin_id, session_id, mfa_proof, now)
        now = self._now()
        payload = dict(order_id=order_id, expected_digest=expected_digest)
        with self.factory.begin() as session:
            row, locked = self._order_lock(session, order_id)
            self._financial_actor(session,row,admin_id,authorize)
            fresh = authorize(session) if authorize is not None else lambda: self._fresh_mfa(verified_at)
            fresh()
            quote = session.get(ManualPayoutQuote, row.quote_id)
            if quote.snapshot.get('approval_policy') != 'SUPPORT_MANUAL_V1' and admin_id != quote.snapshot['owner_admin_id']:
                _fail('WALLET_PAYOUT_OWNER_REQUIRED', 403)
            replay = self._replay(session, admin_id, 'CLAIM', idempotency_key, payload)
            if replay:
                if row.claimed_by != admin_id or row.status != 'CLAIMED':
                    _fail('WALLET_PAYOUT_CLAIM_UNAVAILABLE')
                # The receipt proves the original claim, but an authorized rate
                # adjustment may have changed the payable since that receipt.
                # Project current locked terms without rewriting claim history.
                result = self._claim_result(row, quote)
            else:
                binding, epoch = self._gate(session, row.user_id, now, locked, execution=True)
                now = self._now()
                fresh()
                quote = session.get(ManualPayoutQuote, row.quote_id)
                if row.status != 'REQUESTED':
                    _fail('WALLET_PAYOUT_ALREADY_CLAIMED')
                final_receive = row.final_receive if row.final_receive is not None else Decimal(quote.snapshot['receive'])
                digest_ok = expected_digest in (row.digest, row.adjusted_digest)
                if (not digest_ok or row.digest != _digest(quote.snapshot)
                        or binding.id != quote.snapshot['binding_id'] or epoch != quote.snapshot['safety_epoch']
                        or self.official_config.address != quote.snapshot['official_address']
                        or self.official_config.version != quote.snapshot['official_config_version']
                        or self.owner_admin_id != quote.snapshot['owner_admin_id']):
                    _fail('WALLET_PAYOUT_DIGEST_CONFLICT')
                if self.reserve_policy == 'manual_liquidity' and locked[0].eligible_usdt < final_receive:
                    _fail('WALLET_PAYMENT_LIQUIDITY_INSUFFICIENT')
                reserve_observed_at = _utc(locked[0].observed_at)
                row.status, row.claimed_by, row.claimed_at, row.updated_at = 'CLAIMED', admin_id, now, now
                mark_manual_payout_pending(locked[0])
                result = self._claim_result(row, quote)
                self._record(session, admin_id, 'CLAIM', idempotency_key, payload, result, now)
                if not 0 <= (self._now() - reserve_observed_at).total_seconds() <= 120:
                    _fail('WALLET_RESERVE_UNAVAILABLE', 503)
            fresh()
        # No instruction leaves this method until the claim/audit/outbox transaction commits.
        return result

    def submit_txid(self, *, admin_id, order_id, txid, idempotency_key, authorize=None):
        if not isinstance(txid, str) or re.fullmatch('[0-9a-fA-F]{64}', txid) is None:
            _fail('WALLET_PAYOUT_TXID_INVALID', 400)
        txid = txid.lower()
        now = self._now()
        payload = dict(order_id=order_id, txid=txid)
        with self.factory.begin() as session:
            row, _ = self._order_lock(session, order_id)
            self._financial_actor(session,row,admin_id,authorize)
            fresh = authorize(session) if authorize is not None else lambda: None
            fresh()
            if row.claimed_by != admin_id:
                _fail('WALLET_PAYOUT_CLAIM_UNAVAILABLE', 403)
            replay = self._replay(session, admin_id, 'SUBMIT_TXID', idempotency_key, payload)
            if replay:
                fresh()
                return replay
            if row.status not in {'CLAIMED', 'UNKNOWN'} or row.candidate_txid not in {None, txid}:
                _fail('WALLET_PAYOUT_TXID_CONFLICT')
            if session.scalar(select(ManualPayoutCandidate.id).where(ManualPayoutCandidate.order_id == row.id,
                    ManualPayoutCandidate.txid == txid)) is None:
                session.add(ManualPayoutCandidate(id=str(uuid4()), order_id=row.id, txid=txid, actor_id=admin_id,
                    reason_code='INITIAL_LOCATOR', created_at=self._now()))
            row.candidate_txid, row.status, row.updated_at = txid, 'UNKNOWN', now
            result = self._record(session, admin_id, 'SUBMIT_TXID', idempotency_key, payload, self._result(row), now)
            fresh()
            return result

    @staticmethod
    def _candidates(session, row):
        candidates = set(session.scalars(select(ManualPayoutCandidate.txid).where(ManualPayoutCandidate.order_id == row.id)))
        if row.candidate_txid:
            candidates.add(row.candidate_txid)
        return tuple(sorted(candidates))

    def correct_candidate(self, *, admin_id, session_id, mfa_proof=None, order_id, txid, reason_code, idempotency_key, authorize=None):
        if not isinstance(txid, str) or re.fullmatch('[0-9a-fA-F]{64}', txid) is None:
            _fail('WALLET_PAYOUT_TXID_INVALID', 400)
        if not isinstance(reason_code, str) or re.fullmatch('[A-Z][A-Z0-9_]{2,79}', reason_code) is None:
            _fail('WALLET_PAYOUT_REASON_INVALID', 400)
        txid = txid.lower()
        verified_at = self._now()
        if authorize is None:
            self._mfa(admin_id, session_id, mfa_proof, verified_at)
        payload = dict(order_id=order_id, txid=txid, reason_code=reason_code)
        with self.factory.begin() as session:
            row, _ = self._order_lock(session, order_id)
            self._financial_actor(session,row,admin_id,authorize)
            fresh = authorize(session) if authorize is not None else lambda: self._fresh_mfa(verified_at)
            fresh()
            if row.claimed_by != admin_id:
                _fail('WALLET_PAYOUT_OWNER_REQUIRED', 403)
            replay = self._replay(session, admin_id, 'CORRECT_CANDIDATE', idempotency_key, payload)
            if replay:
                fresh()
                return replay
            if row.status != 'UNKNOWN' or row.candidate_txid is None:
                _fail('WALLET_PAYOUT_CORRECTION_UNAVAILABLE')
            candidates = self._candidates(session, row)
            if txid in candidates:
                _fail('WALLET_PAYOUT_CANDIDATE_ALREADY_RECORDED')
            if len(candidates) >= 10:
                _fail('WALLET_PAYOUT_CANDIDATE_LIMIT')
            now = self._now()
            session.add(ManualPayoutCandidate(id=str(uuid4()), order_id=row.id, txid=txid, actor_id=admin_id,
                reason_code=reason_code, created_at=now))
            result = self._record(session, admin_id, 'CORRECT_CANDIDATE', idempotency_key, payload, self._result(row), now,
                reason_code=reason_code)
            fresh()
            return result

    @staticmethod
    def _matches(evidence, row, quote, txid):
        if (not isinstance(evidence, TransactionEvidence) or evidence.txid != txid
                or evidence.policy != POLICY or evidence.source_id != SOURCE_ID or evidence.network != NETWORK
                or evidence.contract != USDT_CONTRACT or evidence.block_number > evidence.solid_head.height
                or evidence.solid_head.policy != POLICY or evidence.solid_head.source_id != SOURCE_ID
                or evidence.solid_head.network != NETWORK):
            return []
        claim_ms = int(_utc(row.claimed_at).timestamp()*1000)
        return [transfer for transfer in evidence.transfers if transfer.txid == txid
            and transfer.contract == USDT_CONTRACT and transfer.from_address == quote.snapshot['official_address']
            and transfer.to_address == quote.snapshot['target_address'] and transfer.amount_units == int(ManualPayoutService._payable(row, quote)*1000000)
            and transfer.timestamp_ms >= claim_ms and transfer.timestamp_ms == evidence.timestamp_ms
            and transfer.block_number == evidence.block_number and transfer.block_id == evidence.block_id
            and type(transfer.log_index) is int and transfer.log_index >= 0]

    @_precise
    def reconcile(self, *, order_id, authorize=None):
        with self.factory() as session:
            row = session.get(ManualPayoutOrder, order_id)
            if row is None:
                _fail('WALLET_PAYOUT_NOT_FOUND', 404)
            if row.status in {'SETTLED', 'CANCELLED', 'REQUESTED'} or row.review_reason == 'MULTIPLE_MATCHING_PAYOUT_EVENTS':
                return self._result(row)
            candidates = self._candidates(session, row)
        # Every locator/audit is durable before network I/O; never hold DB locks here.
        evidence_by_txid = {}
        for txid in candidates[:10]:
            try:
                evidence_by_txid[txid] = self.finality.transaction_evidence(txid)
            except TronEvidenceUnavailable:
                evidence_by_txid[txid] = None
        now = self._now()
        with self.factory.begin() as session:
            row, locked = self._order_lock(session, order_id)
            fresh = authorize(session) if authorize is not None else lambda: None
            fresh()
            if row.status not in {'CLAIMED', 'UNKNOWN'} or row.review_reason == 'MULTIPLE_MATCHING_PAYOUT_EVENTS':
                return self._result(row)
            if self._candidates(session, row) != candidates:
                return self._result(row)
            quote = session.get(ManualPayoutQuote, row.quote_id)
            now = self._now()
            matches = {(transfer.txid, transfer.log_index): (observed, transfer)
                for txid, observed in evidence_by_txid.items()
                if transaction_evidence_fresh(observed, now)
                for transfer in self._matches(observed, row, quote, txid)}
            matched = next(iter(matches.values())) if len(matches) == 1 and len(candidates) <= 10 else None
            evidence, transfer = matched if matched else (None, None)
            txid = transfer.txid if transfer else None
            used = None
            if transfer:
                used = session.scalar(select(ManualPayoutEvent.id).where(ManualPayoutEvent.network == NETWORK,
                    ManualPayoutEvent.contract == USDT_CONTRACT, ManualPayoutEvent.txid == txid,
                    ManualPayoutEvent.log_index == transfer.log_index))
            if transfer is None or used:
                reason = ('MULTIPLE_MATCHING_PAYOUT_EVENTS' if len(matches) > 1 else
                    'CANDIDATE_LIMIT_EXCEEDED' if len(candidates) > 10 else
                    'EVENT_ALREADY_ALLOCATED' if used else 'EVIDENCE_UNAVAILABLE_OR_MISMATCH')
                if row.status != 'UNKNOWN' or row.review_reason != reason:
                    row.status, row.review_reason, row.updated_at = 'UNKNOWN', reason, now
                    audit_write(session, 'manual-payout-reconciler', row.id, 'wallet.manual_payout_review', reason)
                fresh()
                return self._result(row)
            payable = self._payable(row, quote)
            session.add(ManualPayoutEvent(id=str(uuid4()), order_id=row.id, network=NETWORK, contract=USDT_CONTRACT,
                txid=txid, log_index=transfer.log_index, created_at=now, evidence=dict(policy=evidence.policy,
                    source_id=evidence.source_id, block_number=evidence.block_number, block_id=evidence.block_id,
                    timestamp_ms=evidence.timestamp_ms, amount_units=transfer.amount_units)))
            self.wallet_ledger.post(entries={'HOLD:'+row.user_id: -payable, 'PLATFORM_CUSTODY': payable},
                actor_id='manual-payout-reconciler', reason_code='MANUAL_PAYOUT_SETTLED', idempotency_key=row.id,
                scope='wallet.manual_settle', session=session)
            finish_manual_payout_pending(locked[0])
            row.status, row.review_reason, row.updated_at = 'SETTLED', None, now
            audit_write(session, 'manual-payout-reconciler', row.id, 'wallet.manual_payout_settled', 'MANUAL_PAYOUT_SETTLED')
            session.flush()
            fresh()
            return self._result(row)

    def status(self, *, user_id, order_id):
        with self.factory() as session:
            row = session.get(ManualPayoutOrder, order_id)
            if row is None or row.user_id != user_id:
                _fail('WALLET_PAYOUT_NOT_FOUND', 404)
            return self._result(row)
