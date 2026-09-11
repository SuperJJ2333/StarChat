"""Identity-owned PIN checks; consume participates in the caller's transaction.

The user lock serializes enrollment, PIN failures, and authorized creates. PIN
failures commit in their own transaction before the API raises an error.
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import hashlib
import hmac
import json
import re
import secrets

from argon2 import PasswordHasher as Argon2PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from pydantic import ValidationError
from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import Device, RefreshTokenFamily, User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.payment_pin_models import PaymentPinAuthorization, PaymentPinCredential
from app.modules.identity.wallet_access import require_wallet_actor


def _fail(code, message, status=403):
    raise AppError(code=code, message=message, status_code=status)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


class PaymentPinService:
    def __init__(self, factory, *, require_all=False, rate_limiter=None, clock=None):
        self.factory = factory
        self.require_all = require_all
        self.limiter = rate_limiter
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        # Independent hash namespace and random salt, with the login hasher's
        # Argon2id cost; login's >=12-character policy is deliberately separate.
        self.hasher = Argon2PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4, hash_len=32, salt_len=16)
        self.login_hasher = PasswordHasher()
        self.audit = AuditWriter(factory)

    @staticmethod
    def validate_pin(pin):
        if not isinstance(pin, str) or re.fullmatch('[0-9]{6}', pin) is None:
            _fail('PAYMENT_PIN_INVALID_FORMAT', '支付密码必须为6位数字', 422)

    def _verify(self, encoded, pin):
        try:
            return self.hasher.verify(encoded, pin)
        except (InvalidHashError, VerificationError):
            return False

    def _limit(self, claims, ip, purpose):
        if self.limiter is None:
            return
        for scope, value, limit in [('account', claims.get('sub', ''), 10), ('session', claims.get('family_id', ''), 10), ('ip', ip, 60)]:
            self.limiter.hit('payment-pin:'+purpose+':'+scope+':'+_digest(str(value)), limit=limit, window_seconds=300)

    @staticmethod
    def lock_account(session, user_id):
        # Also held for legacy unconfigured sends, preventing an enrollment race.
        session.scalar(select(User.id).where(User.id == user_id).with_for_update())

    def _identity(self, session, claims):
        if not isinstance(claims, dict) or not all(claims.get(k) for k in ('sub', 'family_id', 'device_id')):
            _fail('AUTH_REQUIRED', '请重新登录后继续', 401)
        require_wallet_actor(session, user_id=claims['sub'], clock=self.clock)
        family = session.execute(select(RefreshTokenFamily.user_id, RefreshTokenFamily.device_id,
            RefreshTokenFamily.revoked_at, RefreshTokenFamily.created_at).where(RefreshTokenFamily.id == claims['family_id']).with_for_update()).first()
        device = session.execute(select(Device.user_id, Device.revoked_at).where(Device.id == claims['device_id']).with_for_update()).first()
        now = self.clock()
        if (family is None or family.user_id != claims['sub'] or family.device_id != claims['device_id']
                or family.revoked_at is not None or device is None or device.user_id != claims['sub']
                or device.revoked_at is not None or _utc(family.created_at) > now
                or not int(claims.get('iat', 0)) <= now.timestamp() < int(claims.get('exp', 0))):
            _fail('ACCESS_TOKEN_INVALID', '登录状态已失效，请重新登录', 401)
        return now

    def _credential(self, session, user_id):
        return session.scalar(select(PaymentPinCredential).where(PaymentPinCredential.user_id == user_id)
            .with_for_update().execution_options(populate_existing=True))

    def status(self, *, claims):
        with self.factory.begin() as session:
            now = self._identity(session, claims)
            credential = self._credential(session, claims['sub'])
            until = _utc(credential.locked_until) if credential and credential.locked_until else None
            return dict(configured=credential is not None, locked_until=until.isoformat() if until and until > now else None)

    def _record(self, session, user_id, action, now, *, result='SUCCESS'):
        self.audit.record_in_session(session, actor_id=user_id, subject_type='payment_pin', subject_id=user_id,
            action=action, result=result, reason_code=action.upper().replace('.', '_'), trace_id=_digest(user_id)[:32])
        OutboxPublisher.enqueue(session, topic='identity', event_type=action, aggregate_type='payment_pin',
            aggregate_id=user_id, payload={'user_id': user_id, 'result': result}, now=now)

    def setup(self, *, claims, pin, login_password, idempotency_key, ip=''):
        self.validate_pin(pin)
        self._key(idempotency_key)
        self._limit(claims, ip, 'setup')
        with self.factory.begin() as session:
            now = self._identity(session, claims)
            encoded = session.scalar(select(User.password_hash).where(User.id == claims['sub']))
            if not isinstance(login_password, str) or not self.login_hasher.verify(encoded, login_password):
                _fail('PASSWORD_INVALID', '登录密码不正确', 401)
            credential = self._credential(session, claims['sub'])
            if credential:
                if (credential.setup_key_hash == _digest(idempotency_key) and credential.setup_family_id == claims['family_id']
                        and self._verify(credential.pin_hash, pin)):
                    return {'configured': True}
                _fail('PAYMENT_PIN_ALREADY_CONFIGURED', '已设置支付密码，请使用现有支付密码', 409)
            session.add(PaymentPinCredential(user_id=claims['sub'], pin_hash=self.hasher.hash(pin), version=1,
                failed_attempts=0, setup_key_hash=_digest(idempotency_key), setup_family_id=claims['family_id'], created_at=now))
            self._record(session, claims['sub'], 'payment_pin.configured', now)
        return {'configured': True}

    @staticmethod
    def _key(key):
        if not isinstance(key, str) or not 1 <= len(key) <= 128 or not key.strip():
            _fail('PAYMENT_INTENT_INVALID', '支付请求标识无效', 422)

    @classmethod
    def intent_hash(cls, action, payload, key):
        cls._key(key)
        if not isinstance(payload, dict) or 'payment_authorization' in payload:
            _fail('PAYMENT_INTENT_INVALID', '支付请求参数无效', 422)
        # Parse the exact public create schema, rejecting unknown fields and
        # giving omitted/null/default and monetary strings a stable meaning.
        from app.api.transfer import CreateChatTransferRequest
        from app.api.redpacket import CreateRedPacketRequest
        from app.api.manual_wallet import PayoutPaymentIntent
        model = {'chat_transfer.create': CreateChatTransferRequest, 'red_packet.create': CreateRedPacketRequest,
            'wallet.payout.create': PayoutPaymentIntent}.get(action)
        if model is None:
            _fail('PAYMENT_INTENT_INVALID', '支付用途无效', 422)
        try:
            normalized = model.model_validate(payload).model_dump(exclude={'payment_authorization'})
        except ValidationError:
            _fail('PAYMENT_INTENT_INVALID', '支付请求参数无效', 422)
        for k, value in normalized.items():
            if isinstance(value, Decimal):
                normalized[k] = format(value.quantize(Decimal('0.01')), 'f')
        if action == 'chat_transfer.create':
            normalized['note'] = (normalized.get('note') or '').strip() or None
        return _digest(json.dumps(dict(action=action, payload=normalized, idempotency_key=key), ensure_ascii=True, sort_keys=True, separators=(',', ':')))

    def authorize(self, *, claims, pin, action, payload, idempotency_key, ip=''):
        self.validate_pin(pin)
        intent = self.intent_hash(action, payload, idempotency_key)
        self._limit(claims, ip, 'authorize')
        error = None
        with self.factory.begin() as session:
            now = self._identity(session, claims)
            credential = self._credential(session, claims['sub'])
            if credential is None:
                _fail('PAYMENT_PIN_SETUP_REQUIRED', '请先设置支付密码', 409)
            if credential.locked_until and _utc(credential.locked_until) > now:
                _fail('PAYMENT_PIN_LOCKED', '支付密码已锁定，请15分钟后重试', 429)
            if credential.locked_until:
                credential.failed_attempts, credential.locked_until = 0, None
            if not self._verify(credential.pin_hash, pin):
                credential.failed_attempts += 1
                if credential.failed_attempts >= 5:
                    credential.locked_until = now + timedelta(minutes=15)
                    error = AppError(code='PAYMENT_PIN_LOCKED', message='支付密码错误次数过多，请15分钟后重试', status_code=429)
                else:
                    error = AppError(code='PAYMENT_PIN_INCORRECT', message=f'支付密码不正确，还可尝试{5-credential.failed_attempts}次', status_code=403)
                self._record(session, claims['sub'], 'payment_pin.verification_failed', now, result='FAILURE')
            else:
                credential.failed_attempts = 0
                token = secrets.token_urlsafe(32)
                session.add(PaymentPinAuthorization(token_hash=_digest(token), user_id=claims['sub'], family_id=claims['family_id'],
                    credential_version=credential.version, intent_hash=intent, created_at=now, expires_at=now+timedelta(seconds=300)))
                self._record(session, claims['sub'], 'payment_pin.authorized', now)
        if error is not None:
            raise error
        return {'authorization': token, 'expires_in': 300}

    def reject_legacy(self, session, *, user_id):
        self.lock_account(session, user_id)
        credential = self._credential(session, user_id)
        if credential or self.require_all:
            _fail('PAYMENT_PIN_REQUIRED' if credential else 'PAYMENT_PIN_SETUP_REQUIRED', '请更新客户端并通过聊天转账验证支付密码', 403)

    def consume(self, session, *, user_id, claims, action, payload, idempotency_key, authorization, existing=False, required=False):
        self.lock_account(session, user_id)
        credential = self._credential(session, user_id)
        if credential is None:
            if required or self.require_all or authorization is not None:
                _fail('PAYMENT_PIN_SETUP_REQUIRED', '请先设置支付密码', 409)
            return
        now = self._identity(session, claims)
        if claims['sub'] != user_id:
            _fail('PAYMENT_AUTHORIZATION_INVALID', '支付授权已失效', 403)
        if not isinstance(authorization, str) or not 20 <= len(authorization) <= 256:
            _fail('PAYMENT_PIN_REQUIRED', '请输入支付密码', 403)
        intent = self.intent_hash(action, payload, idempotency_key)
        ticket = session.scalar(select(PaymentPinAuthorization).where(PaymentPinAuthorization.token_hash == _digest(authorization)).with_for_update())
        if (ticket is None or ticket.user_id != user_id or ticket.family_id != claims['family_id']
                or ticket.credential_version != credential.version or not hmac.compare_digest(ticket.intent_hash, intent)
                or (ticket.consumed_at is not None and not existing)
                or (ticket.consumed_at is None and _utc(ticket.expires_at) <= now)):
            _fail('PAYMENT_AUTHORIZATION_INVALID', '支付授权已失效，请重新输入支付密码', 403)
        if ticket.consumed_at is None:
            ticket.consumed_at = now
            self._record(session, user_id, 'payment_pin.consumed', now)
