"""Fixed admin operation passwords; never a fallback or substitute for user MFA."""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
from uuid import uuid4
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.wallet_access import require_wallet_actor, require_wallet_session
from app.modules.identity.operation_password_models import AdminOperationCredential, AdminOperationAttempt, AdminOperationCommand
from app.modules.ledger.reserve import lock_budget


def error(code, status=403):
    return AppError(code=code,message=code,status_code=status)


def aware(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class _Rejected(Exception):
    def __init__(self, code, status=401): self.code,self.status=code,status


@dataclass(frozen=True)
class OperationPasswordProof:
    user_id: str
    session_id: str
    device_id: str
    version: int
    verified_at: datetime


class AdminWalletOperationPasswordService:
    def __init__(self,factory,*,owner_id,auth_mode,clock,password_hasher=None):
        self.factory,self.owner_id,self.auth_mode,self.clock=factory,owner_id,auth_mode,clock
        self.hasher=password_hasher or PasswordHasher()
        self.audit=AuditWriter(factory,now_factory=clock)

    def _identity(self,session,claims,verified_at,*,grant_verification=False):
        lock_budget(session)
        if not self.owner_id() or claims['sub'] != self.owner_id():
            raise error('PERMISSION_DENIED')
        require_wallet_actor(session,user_id=claims['sub'],clock=self.clock,administrator=True)
        def check():
            try:
                return require_wallet_session(session,claims=claims,clock=self.clock,verified_at=verified_at,
                    require_recent=not (grant_verification and claims.get('session_scope')=='admin'))
            except AppError as exc:
                if exc.code=='TOTP_REQUIRED': raise error('OPERATION_PASSWORD_REQUIRED') from None
                raise
        session_fresh=check()
        def fresh():
            if claims['sub']!=self.owner_id(): raise error('PERMISSION_DENIED')
            try: session_fresh()
            except AppError as exc:
                if exc.code=='TOTP_REQUIRED': raise error('OPERATION_PASSWORD_REQUIRED') from None
                raise
        return fresh

    @staticmethod
    def _credential(session,user_id):
        return session.scalar(select(AdminOperationCredential).where(AdminOperationCredential.user_id==user_id)
            .with_for_update().execution_options(populate_existing=True))

    def _view(self,row):
        return dict(auth_mode=self.auth_mode(),configured=row is not None,version=row.version if row else 0)

    def status(self,*,claims,authorization=None,grant_verification=False):
        with self.factory.begin() as session:
            fresh=authorization(session) if authorization is not None else self._identity(session,claims,self.clock(),
                grant_verification=grant_verification)
            result=self._view(self._credential(session,claims['sub']))
            fresh()
            return result

    def _record(self,session,user_id,action,result,version,now):
        payload=dict(version=version,auth_mode='operation_password')
        self.audit.record_in_session(session,actor_id=user_id,subject_type='admin_operation_credential',
            subject_id=user_id,action=action,result=result,reason_code=action.upper().replace('.','_'),
            trace_id=str(uuid4()),after=payload)
        if result=='SUCCESS':
            OutboxPublisher.enqueue(session,topic='identity.admin_operation',event_type=action,aggregate_type='admin_operation_credential',
                aggregate_id=user_id,payload=payload,now=now)

    def _execute(self,claims,action,*,grant_verification=False):
        failure=None
        with self.factory.begin() as session:
            now=self.clock()
            fresh=self._identity(session,claims,now,grant_verification=grant_verification)
            row=self._credential(session,claims['sub'])
            attempt=session.get(AdminOperationAttempt,claims['sub'],with_for_update=True)
            if attempt is None:
                attempt=AdminOperationAttempt(user_id=claims['sub'],failed_count=0,window_started_at=now)
                session.add(attempt)
            if attempt.locked_until is not None and now<aware(attempt.locked_until):
                failure=error('OPERATION_PASSWORD_RATE_LIMITED',429)
            else:
                if now-aware(attempt.window_started_at)>=timedelta(minutes=15):
                    attempt.failed_count,attempt.window_started_at,attempt.locked_until=0,now,None
                try:
                    result=action(session,row,now)
                except _Rejected as exc:
                    attempt.failed_count+=1
                    if attempt.failed_count>=5: attempt.locked_until=now+timedelta(minutes=15)
                    self._record(session,claims['sub'],'identity.admin_operation.rejected','FAILURE',row.version if row else 0,now)
                    failure=error(exc.code,exc.status)
                # A successful replay of an old setup must not reset the guess
                # budget for the current credential. Only window expiry resets.
            fresh()
        # Failures must commit the durable limiter and audit before surfacing.
        if failure: raise failure
        return result

    def set_password(self,*,claims,login_password,new_operation_password,current_operation_password=None,idempotency_key):
        if (not isinstance(new_operation_password,str) or not 12<=len(new_operation_password)<=128
                or not isinstance(login_password,str) or not 1<=len(login_password)<=256
                or current_operation_password is not None and (not isinstance(current_operation_password,str) or not 12<=len(current_operation_password)<=128)):
            raise error('OPERATION_PASSWORD_POLICY',422)
        if not isinstance(idempotency_key,str) or not idempotency_key.strip() or len(idempotency_key)>128:
            raise error('IDEMPOTENCY_KEY_REQUIRED',422)
        exact=json.dumps(dict(login_password=login_password,new_operation_password=new_operation_password,
            current_operation_password=current_operation_password),sort_keys=True,separators=(',',':'),ensure_ascii=False)
        def change(session,row,now):
            login_hash=session.scalar(select(User.password_hash).where(User.id==claims['sub']))
            if not self.hasher.verify(login_hash,login_password): raise _Rejected('LOGIN_PASSWORD_INVALID')
            previous=session.scalar(select(AdminOperationCommand).where(AdminOperationCommand.actor_id==claims['sub'],
                AdminOperationCommand.idempotency_key==idempotency_key))
            if previous is not None:
                if not self.hasher.verify(previous.request_hash,exact): raise _Rejected('OPERATION_PASSWORD_IDEMPOTENCY_CONFLICT',409)
                return dict(previous.result)
            if self.hasher.verify(login_hash,new_operation_password): raise _Rejected('OPERATION_PASSWORD_MUST_DIFFER')
            if row is None:
                if current_operation_password is not None: raise _Rejected('OPERATION_PASSWORD_NOT_CONFIGURED')
            elif current_operation_password is None or not self.hasher.verify(row.password_hash,current_operation_password):
                raise _Rejected('OPERATION_PASSWORD_INVALID')
            new_hash=self.hasher.hash(new_operation_password)
            if row is None:
                row=AdminOperationCredential(user_id=claims['sub'],password_hash=new_hash,version=1,created_at=now,updated_at=now)
                session.add(row)
            else: row.password_hash,row.version,row.updated_at=new_hash,row.version+1,now
            result=self._view(row)
            session.add(AdminOperationCommand(id=str(uuid4()),actor_id=claims['sub'],idempotency_key=idempotency_key,
                request_hash=self.hasher.hash(exact),credential_version=row.version,result=result,created_at=now))
            self._record(session,claims['sub'],'identity.admin_operation.changed','SUCCESS',row.version,now)
            session.flush()
            return result
        return self._execute(claims,change)

    def verify(self,*,claims,operation_password,grant_verification=False):
        if self.auth_mode()!='operation_password': raise error('ADMIN_WALLET_AUTH_MODE_MISMATCH')
        if not isinstance(operation_password,str) or not 12<=len(operation_password)<=128:
            raise error('OPERATION_PASSWORD_REQUIRED')
        def verify(session,row,now):
            if row is None: raise _Rejected('OPERATION_PASSWORD_NOT_CONFIGURED')
            if not self.hasher.verify(row.password_hash,operation_password): raise _Rejected('OPERATION_PASSWORD_INVALID')
            self._record(session,claims['sub'],'identity.admin_operation.verified','SUCCESS',row.version,now)
            return OperationPasswordProof(claims['sub'],claims['family_id'],claims['device_id'],row.version,now)
        return self._execute(claims,verify,grant_verification=grant_verification)

    def authorization(self,*,claims,proof):
        def authorize(session):
            if (self.auth_mode()!='operation_password' or not isinstance(proof,OperationPasswordProof)
                    or (proof.user_id,proof.session_id,proof.device_id)!=(claims['sub'],claims['family_id'],claims['device_id'])):
                raise error('OPERATION_PASSWORD_REQUIRED')
            fresh=self._identity(session,claims,proof.verified_at)
            row=self._credential(session,claims['sub'])
            if row is None or row.version!=proof.version: raise error('OPERATION_PASSWORD_CHANGED')
            def final():
                if self.auth_mode()!='operation_password': raise error('ADMIN_WALLET_AUTH_MODE_MISMATCH')
                fresh()
            final()
            return final
        return authorize
