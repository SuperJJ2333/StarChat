"""Fixed, session-bound wallet authentication. Financial callers retain their locks."""
from datetime import timedelta
from hashlib import sha256
import json
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import AdminSession, TotpCredential, User, UserRole
from app.modules.identity.operation_password import AdminWalletOperationPasswordService, aware, error
from app.modules.identity.operation_password_models import AdminOperationCredential
from app.modules.identity.wallet_access import require_wallet_actor, require_wallet_session
from app.modules.identity.wallet_grant_models import WalletAccessGrant, WalletAccessAttempt
from app.modules.ledger.reserve import lock_budget


def digest(value):
    return sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()


class WalletAccessGrantService:
    def __init__(self, settings, factory, clock):
        self.settings, self.factory, self.clock = settings, factory, clock
        self.audit = AuditWriter(factory, now_factory=clock)

    def _configuration(self):
        return digest([self.settings.wallet_admin_auth_mode, self.settings.wallet_manual_owner_admin_id,
            getattr(self.settings, 'wallet_access_policy_version', 'wallet-access-v1'),
            getattr(self.settings, 'wallet_manual_policy_version', None),
            getattr(self.settings, 'wallet_official_config_version', None), self.settings.wallet_real_mode])

    def _identity(self, session, claims):
        lock_budget(session)
        if (claims.get('session_scope') != 'admin' or not self.settings.wallet_manual_owner_admin_id
                or claims['sub'] != self.settings.wallet_manual_owner_admin_id
                or self.settings.wallet_real_mode != 'manual_tron'):
            raise error('PERMISSION_DENIED')
        require_wallet_actor(session, user_id=claims['sub'], clock=self.clock, administrator=True)
        return require_wallet_session(session, claims=claims, clock=self.clock, verified_at=None,
            require_recent=False, require_proof=False)

    def _credential(self, session, claims):
        mode = self.settings.wallet_admin_auth_mode
        if mode == 'operation_password':
            row = session.execute(select(AdminOperationCredential.version, AdminOperationCredential.password_hash)
                .where(AdminOperationCredential.user_id == claims['sub']).with_for_update()).first()
            credential = list(row) if row else None
        elif mode == 'totp':
            row = session.execute(select(TotpCredential.id, TotpCredential.encrypted_secret, TotpCredential.enabled)
                .where(TotpCredential.user_id == claims['sub']).with_for_update()).first()
            credential = list(row) if row and row.enabled else None
        else:
            raise error('ADMIN_WALLET_AUTH_MODE_MISMATCH')
        if credential is None:
            return None
        roles = session.execute(select(UserRole.id, UserRole.role_code, UserRole.assigned_at)
            .where(UserRole.user_id == claims['sub']).order_by(UserRole.id)).all()
        password_hash = session.scalar(select(User.password_hash).where(User.id == claims['sub']))
        return digest([mode, credential, [list(r) for r in roles], password_hash])

    @staticmethod
    def _row(session, claims):
        return session.scalar(select(WalletAccessGrant).where(WalletAccessGrant.family_id == claims['family_id'])
            .with_for_update().execution_options(populate_existing=True))

    def _valid(self, row, claims, credential):
        return bool(getattr(self.settings, 'wallet_access_grant_enabled', False) and row is not None
            and (row.user_id, row.family_id, row.device_id, row.scope) ==
                (claims['sub'], claims['family_id'], claims['device_id'], 'wallet-admin')
            and row.revoked_at is None and row.auth_mode == self.settings.wallet_admin_auth_mode
            and row.configuration_digest == self._configuration() and credential is not None
            and row.credential_digest == credential
            and aware(row.verified_at) <= self.clock() < aware(row.expires_at))

    def _view(self, row, claims, credential):
        valid = self._valid(row, claims, credential)
        return dict(enabled=getattr(self.settings, 'wallet_access_grant_enabled', False), verified=valid,
            auth_mode=self.settings.wallet_admin_auth_mode, configured=credential is not None,
            grant_id=row.grant_id if valid else None,
            verified_at=aware(row.verified_at).isoformat() if valid else None,
            expires_at=aware(row.expires_at).isoformat() if valid else None,
            server_time=self.clock().isoformat())

    def status(self, *, claims):
        with self.factory.begin() as session:
            fresh = self._identity(session, claims)
            credential = self._credential(session, claims)
            result = self._view(self._row(session, claims), claims, credential)
            fresh()
            return result

    def require(self, *, claims):
        with self.factory.begin() as session:
            self.authorization(claims=claims)(session)()

    def authorization(self, *, claims):
        def authorize(session):
            fresh = self._identity(session, claims)
            credential = self._credential(session, claims)
            row = self._row(session, claims)
            def final():
                fresh()
                # Repeat live scalar reads after downstream lock waits. Row locks
                # serialize session replacement, credential changes and revoke.
                self._identity(session, claims)()
                if not self._valid(self._row(session, claims), claims, self._credential(session, claims)):
                    raise error('WALLET_ACCESS_REQUIRED')
            if not self._valid(row, claims, credential):
                raise error('WALLET_ACCESS_REQUIRED')
            final()
            return final
        return authorize

    def _record(self, session, claims, row, action):
        payload = dict(grant_id=row.grant_id, scope=row.scope, auth_mode=row.auth_mode)
        self.audit.record_in_session(session, actor_id=claims['sub'], subject_type='wallet_access_grant',
            subject_id=row.grant_id, action=action, result='SUCCESS', reason_code=action.upper().replace('.', '_'),
            trace_id=str(uuid4()), after=payload)
        OutboxPublisher.enqueue(session, topic='identity.wallet_access', event_type=action,
            aggregate_type='wallet_access_grant', aggregate_id=row.grant_id, payload=payload, now=self.clock())

    def _totp_attempt(self, claims):
        with self.factory.begin() as session:
            self._identity(session, claims)()
            row = session.get(WalletAccessAttempt, claims['sub'], with_for_update=True)
            now = self.clock()
            if row is None:
                row = WalletAccessAttempt(user_id=claims['sub'], attempt_count=0, window_started_at=now)
                session.add(row)
            if now-aware(row.window_started_at) >= timedelta(minutes=5):
                row.attempt_count, row.window_started_at = 0, now
            if row.attempt_count >= 5:
                raise error('WALLET_ACCESS_RATE_LIMITED', 429)
            row.attempt_count += 1
            self.audit.record_in_session(session, actor_id=claims['sub'], subject_type='wallet_access_grant',
                subject_id=claims['family_id'], action='identity.wallet_access.verification_attempt', result='PENDING',
                reason_code='WALLET_ACCESS_VERIFICATION_ATTEMPT', trace_id=str(uuid4()), after={'auth_mode':'totp'})

    def verify(self, *, claims, operation_password=None, mfa_proof=None, mfa_verifier=None):
        if not getattr(self.settings, 'wallet_access_grant_enabled', False):
            raise error('WALLET_ACCESS_DISABLED')
        mode = self.settings.wallet_admin_auth_mode
        if (mode == 'operation_password' and (mfa_proof is not None or operation_password is None)
                or mode == 'totp' and (operation_password is not None or mfa_proof is None)):
            raise error('ADMIN_WALLET_AUTH_MODE_MISMATCH')
        with self.factory.begin() as session:
            self._identity(session, claims)()
            credential = self._credential(session, claims)
            configuration = self._configuration()
            row = self._row(session, claims)
            original_state = (row.grant_id, row.revoked_at) if row else None
            if self._valid(row, claims, credential):
                return self._view(row, claims, credential)
        started = self.clock()
        if mode == 'operation_password':
            service = AdminWalletOperationPasswordService(self.factory,
                owner_id=lambda:self.settings.wallet_manual_owner_admin_id,
                auth_mode=lambda:self.settings.wallet_admin_auth_mode, clock=self.clock)
            service.verify(claims=claims, operation_password=operation_password, grant_verification=True)
        elif mode == 'totp':
            if mfa_verifier is None:
                raise error('WALLET_MFA_NOT_CONFIGURED', 503)
            self._totp_attempt(claims)
            try:
                if mfa_verifier(user_id=claims['sub'], session_id=claims['family_id'], proof=mfa_proof, now=self.clock()) is not True:
                    raise error('TOTP_REQUIRED')
            except AppError as exc:
                self.audit.record(actor_id=claims['sub'], subject_type='wallet_access_grant',
                    subject_id=claims['family_id'], action='identity.wallet_access.rejected', result='FAILURE',
                    reason_code=exc.code, trace_id=str(uuid4()), after={'auth_mode':'totp'})
                raise
        else:
            raise error('ADMIN_WALLET_AUTH_MODE_MISMATCH')
        with self.factory.begin() as session:
            fresh = self._identity(session, claims)
            current = self._credential(session, claims)
            row = self._row(session, claims)
            current_state = (row.grant_id, row.revoked_at) if row else None
            if (not getattr(self.settings, 'wallet_access_grant_enabled', False)
                    or configuration != self._configuration() or current is None or credential != current
                    or original_state != current_state and not self._valid(row, claims, current)
                    or not timedelta(0) <= self.clock()-started <= timedelta(seconds=30)):
                raise error('WALLET_ACCESS_REQUIRED')
            if not self._valid(row, claims, current):
                now = self.clock()
                if row is None:
                    row = WalletAccessGrant(family_id=claims['family_id'])
                    session.add(row)
                row.grant_id, row.user_id, row.device_id = str(uuid4()), claims['sub'], claims['device_id']
                row.scope, row.auth_mode = 'wallet-admin', mode
                row.configuration_digest, row.credential_digest = configuration, current
                admin_deadline = session.scalar(select(AdminSession.expires_at).where(AdminSession.user_id == claims['sub']))
                row.verified_at, row.expires_at, row.revoked_at = now, min(now+timedelta(minutes=60), aware(admin_deadline)), None
                self._record(session, claims, row, 'identity.wallet_access.verified')
                session.flush()
            fresh()
            return self._view(row, claims, current)

    def revoke(self, *, claims):
        with self.factory.begin() as session:
            fresh = self._identity(session, claims)
            credential = self._credential(session, claims)
            row = self._row(session, claims)
            if row is None:
                now = self.clock()
                row = WalletAccessGrant(family_id=claims['family_id'], grant_id=str(uuid4()), user_id=claims['sub'],
                    device_id=claims['device_id'], scope='wallet-admin', auth_mode=self.settings.wallet_admin_auth_mode,
                    configuration_digest=self._configuration(), credential_digest=credential or '',
                    verified_at=now, expires_at=now+timedelta(minutes=60))
                session.add(row)
            # Every explicit revoke is a new tombstone, even when a previous
            # grant was already revoked and the trusted clock has not ticked.
            # This cancels verification that began against the older tombstone.
            row.grant_id = str(uuid4())
            row.revoked_at = self.clock()
            self._record(session, claims, row, 'identity.wallet_access.revoked')
            fresh()
            return self._view(row, claims, credential)
