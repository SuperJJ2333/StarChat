"""Password-confirmed MFA enrollment; existing enabled secrets are never reset."""
from base64 import b32encode
from datetime import datetime, timezone
import hashlib
import hmac
import json
import re
import secrets
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import Device, RefreshTokenFamily, TotpCredential, User
from app.modules.identity.totp import TotpService
from app.modules.identity.wallet_access import require_wallet_actor


def _fail(code, message, status=403):
    raise AppError(code=code, message=message, status_code=status)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class WalletMfaService:
    def __init__(self, factory, *, protector, password_hasher, rate_limiter, clock):
        self.factory, self.protector, self.hasher = factory, protector, password_hasher
        self.limiter, self.clock = rate_limiter, clock
        self.audit = AuditWriter(factory)

    def status(self, *, user_id):
        """Read credential metadata without requiring or decrypting its secret."""
        with self.factory() as session:
            row = session.execute(select(TotpCredential.id, TotpCredential.enabled,
                TotpCredential.created_at).where(TotpCredential.user_id == user_id)).one_or_none()
            return dict(configured=self.protector is not None,
                enabled=bool(row.enabled) if row else False,
                enrolled_at=_utc(row.created_at).isoformat() if row else None,
                pending_credential_id=row.id if row and not row.enabled else None)

    def _require_protector(self):
        if self.protector is None:
            _fail('WALLET_MFA_NOT_CONFIGURED', '动态验证配置尚未就绪', 503)
        return self.protector

    def _authorize(self, session, user_id, session_id, password=None, *, setup_proof=None, credential_id=None):
        require_wallet_actor(session, user_id=user_id, clock=self.clock)
        now = self.clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise ValueError('aware server clock required')
        family = session.execute(select(RefreshTokenFamily.user_id, RefreshTokenFamily.device_id,
            RefreshTokenFamily.revoked_at, RefreshTokenFamily.created_at).where(RefreshTokenFamily.id == session_id)).one_or_none()
        if (family is None or family.user_id != user_id or family.revoked_at is not None
                or (now-_utc(family.created_at)).total_seconds() < 0):
            _fail('RECENT_LOGIN_REQUIRED', '请重新登录后设置动态验证')
        device = session.execute(select(Device.user_id, Device.revoked_at).where(Device.id == family.device_id)).one_or_none()
        if device is None or device.user_id != user_id or device.revoked_at is not None:
            _fail('AUTH_REQUIRED', '登录设备已失效', 401)
        if password is not None:
            encoded = session.scalar(select(User.password_hash).where(User.id == user_id))
            if not isinstance(password, str) or not self.hasher.verify(encoded, password):
                _fail('PASSWORD_INVALID', '密码验证失败', 401)
        elif setup_proof is not None:
            self._verify_setup_proof(session, setup_proof, user_id, session_id, credential_id, now)
        elif (now-_utc(family.created_at)).total_seconds() > 300:
            _fail('RECENT_LOGIN_REQUIRED', '请在当前页面验证登录密码后继续设置动态验证')
        return now

    def _setup_proof(self, session, user_id, session_id, credential_id, now):
        encoded = session.scalar(select(User.password_hash).where(User.id == user_id))
        return self._require_protector().encrypt(json.dumps(dict(
            purpose='wallet-mfa-enable-v1', user=user_id, family=session_id,
            credential=credential_id, issued=now.timestamp(),
            password=hashlib.sha256(encoded.encode()).hexdigest())))

    def _verify_setup_proof(self, session, proof, user_id, session_id, credential_id, now):
        try:
            if not isinstance(proof, str) or len(proof) > 4096:
                raise ValueError('invalid proof')
            data = json.loads(self._require_protector().decrypt(proof))
            encoded = session.scalar(select(User.password_hash).where(User.id == user_id))
            valid = (data['purpose'] == 'wallet-mfa-enable-v1'
                and data['user'] == user_id and data['family'] == session_id
                and data['credential'] == credential_id
                and type(data['issued']) in (int, float)
                and 0 <= now.timestamp()-data['issued'] < 300
                and hmac.compare_digest(data['password'], hashlib.sha256(encoded.encode()).hexdigest()))
        except Exception:
            valid = False
        if not valid:
            _fail('MFA_SETUP_PROOF_INVALID', '安全验证已过期或失效，请在当前页面再次验证登录密码', 403)

    def reauthenticate(self, *, user_id, session_id, credential_id, password):
        self._require_protector()
        self._limit(user_id)
        self._require_credential_id(credential_id)
        if not isinstance(password, str) or not password:
            _fail('PASSWORD_INVALID', '需要验证当前密码', 401)
        with self.factory.begin() as session:
            now = self._authorize(session, user_id, session_id, password)
            row = self._credential(session, user_id, credential_id)
            if row.enabled:
                _fail('TOTP_ALREADY_ENABLED', '动态验证已启用', 409)
            proof = self._setup_proof(session, user_id, session_id, row.id, now)
            self._record(session, user_id, row.id, 'identity.totp.setup_reauthenticated', now)
            return {'setup_proof': proof, 'expires_in': 300}

    def _limit(self, user_id):
        if not isinstance(user_id, str) or not user_id:
            _fail('AUTH_REQUIRED', '需要登录', 401)
        self.limiter.hit('wallet-mfa-setup:'+hashlib.sha256(user_id.encode()).hexdigest(), limit=5, window_seconds=300)

    def _record(self, session, user_id, credential_id, action, now):
        self.audit.record_in_session(session, actor_id=user_id, subject_type='totp_credential',
            subject_id=credential_id, action=action, result='SUCCESS', reason_code=action.upper().replace('.', '_'),
            trace_id=credential_id)
        OutboxPublisher.enqueue(session, topic='identity', event_type=action, aggregate_type='totp_credential',
            aggregate_id=credential_id, payload={'user_id': user_id, 'credential_id': credential_id}, now=now)

    @staticmethod
    def _credential(session, user_id, credential_id=None):
        row = session.scalar(select(TotpCredential).where(TotpCredential.user_id == user_id)
            .with_for_update().execution_options(populate_existing=True))
        if credential_id is not None and (row is None or row.id != credential_id):
            _fail('TOTP_ENROLLMENT_NOT_FOUND', '动态验证配置已失效', 404)
        return row

    def begin(self, *, user_id, session_id, password):
        protector = self._require_protector()
        self._limit(user_id)
        if not isinstance(password, str) or not password:
            _fail('PASSWORD_INVALID', '需要验证当前密码', 401)
        with self.factory.begin() as session:
            now = self._authorize(session, user_id, session_id, password)
            if self._credential(session, user_id) is not None:
                _fail('TOTP_ALREADY_ENROLLED', '已有动态验证配置，请完成现有配置', 409)
            secret = b32encode(secrets.token_bytes(20)).decode().rstrip('=')
            credential = TotpCredential(id=str(uuid4()), user_id=user_id,
                encrypted_secret=protector.encrypt(secret), enabled=False, created_at=now)
            session.add(credential)
            self._record(session, user_id, credential.id, 'identity.totp.enrolled', now)
            session.flush()
            result = {'credential_id': credential.id, 'secret': secret,
                'setup_proof': self._setup_proof(session, user_id, session_id, credential.id, now)}
        return result

    def enable(self, *, user_id, session_id, credential_id, code, setup_proof=None):
        protector = self._require_protector()
        self._limit(user_id)
        self._require_credential_id(credential_id)
        if not isinstance(code, str) or re.fullmatch('[0-9]{6}', code) is None:
            _fail('TOTP_INVALID', '动态验证码无效', 401)
        with self.factory.begin() as session:
            self._authorize(session, user_id, session_id, setup_proof=setup_proof, credential_id=credential_id)
            row = self._credential(session, user_id, credential_id)
            if row.enabled:
                _fail('TOTP_ALREADY_ENABLED', '动态验证已启用', 409)
            now = self._authorize(session, user_id, session_id, setup_proof=setup_proof, credential_id=credential_id)
            secret = protector.decrypt(row.encrypted_secret)
            if not hmac.compare_digest(TotpService.code_at(secret, now), code):
                _fail('TOTP_INVALID', '动态验证码无效', 401)
            row.enabled, row.last_accepted_step = True, int(now.timestamp()) // 30
            self._record(session, user_id, row.id, 'identity.totp.enabled', now)
        return {'enabled': True}

    def abort_pending(self, *, user_id, session_id, credential_id, password):
        self._limit(user_id)
        self._require_credential_id(credential_id)
        if not isinstance(password, str) or not password:
            _fail('PASSWORD_INVALID', '需要验证当前密码', 401)
        with self.factory.begin() as session:
            now = self._authorize(session, user_id, session_id, password)
            row = self._credential(session, user_id, credential_id)
            if row.enabled:
                _fail('TOTP_ALREADY_ENABLED', '已启用的动态验证不能通过此入口重置', 409)
            session.delete(row)
            self._record(session, user_id, row.id, 'identity.totp.pending_aborted', now)
        return {'enabled': False}

    @staticmethod
    def _require_credential_id(credential_id):
        if not isinstance(credential_id, str) or not credential_id.strip() or len(credential_id) > 36:
            _fail('TOTP_ENROLLMENT_NOT_FOUND', '动态验证配置已失效', 404)
