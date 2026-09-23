"""Support-order coordination over the existing payout financial engine."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import secrets
import re

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.core.errors import AppError
from app.modules.identity.support_order_auth import SupportOrderSessionAuthorizer
from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote
from app.modules.wallet.safety import audit_write


class SupportPayoutState(Base):
    __tablename__ = 'wallet_support_payout_states'
    order_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_orders.id'), primary_key=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    claimed_by: Mapped[str | None] = mapped_column(String(36))
    claim_token: Mapped[str | None] = mapped_column(String(64))
    claim_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    execution_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    review_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    review_authorized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def support_payout_projection(session, row, now, actor=None):
    state = session.get(SupportPayoutState, row.id)
    if state is None:
        return {}
    if row.status == 'SETTLED':
        stage = 'COMPLETED'
    elif row.status == 'CANCELLED':
        stage = 'CANCELLED'
    elif row.status == 'UNKNOWN' or (not state.review_authorized_at and (state.review_required or now >= utc(state.expires_at))):
        stage = 'NEEDS_REVIEW'
    elif state.review_authorized_at and not state.execution_started_at:
        stage = 'REVIEWING' if state.claim_expires_at and now < utc(state.claim_expires_at) else 'NEEDS_REVIEW'
    elif state.execution_started_at:
        stage = 'PAYMENT_STARTED'
    elif state.claimed_by and state.claim_expires_at and now < utc(state.claim_expires_at):
        stage = 'PROCESSING'
    else:
        stage = 'WAITING_SUPPORT'
    return dict(expires_at=utc(state.expires_at).isoformat(),processing_stage=stage,
        claimed_by=state.claimed_by,claim_expires_at=utc(state.claim_expires_at).isoformat() if state.claim_expires_at else None,
        execution_started_at=utc(state.execution_started_at).isoformat() if state.execution_started_at else None,
        review_authorized_at=utc(state.review_authorized_at).isoformat() if state.review_authorized_at else None,
        **({'claim_token':state.claim_token} if actor and state.claimed_by==actor else {}))


def expire_support_payout_orders(factory, *, now, limit=100):
    """Public worker sweep. No provider, balance write, unfreeze or reassignment."""
    if now.tzinfo is None or type(limit) is not int or not 1<=limit<=1000:
        raise ValueError('aware server time and bounded batch required')
    with factory.begin() as session:
        states=session.scalars(select(SupportPayoutState).join(ManualPayoutOrder,
            ManualPayoutOrder.id==SupportPayoutState.order_id).where(SupportPayoutState.expires_at<=now,
            SupportPayoutState.review_required.is_(False),ManualPayoutOrder.status.not_in(('SETTLED','CANCELLED')))
            .order_by(SupportPayoutState.expires_at).limit(limit).with_for_update(of=SupportPayoutState)).all()
        for state in states:
            state.review_required=True
            audit_write(session,'support-payout-deadline',state.order_id,'wallet.support_payout_expired','SUPPORT_PAYOUT_TWO_HOUR_REVIEW')
    return len(states)


class _PayoutAuthorization:
    scope = 'support-orders'

    def __init__(self, service, claims, order_id, claim_token, *, begin=False, evidence=False):
        self.service,self.claims,self.order_id,self.token = service,claims,order_id,claim_token
        self.begin,self.evidence=begin,evidence

    def __call__(self, session):
        fresh = self.service.order_access.authorization(claims=self.claims)(session)
        state=session.get(SupportPayoutState,self.order_id,with_for_update=True)
        self.service._held(state,self.claims,self.token,evidence=self.evidence)
        row=session.get(ManualPayoutOrder,self.order_id)
        if row is None or row.status=='CANCELLED': fail('SUPPORT_PAYOUT_UNAVAILABLE')
        if self.begin and state.execution_started_at is None:
            state.execution_started_at=self.service.payout._now()
            audit_write(session,self.claims['sub'],row.id,'wallet.support_payout_started','SUPPORT_PAYOUT_STARTED')
        elif not self.begin and state.execution_started_at is None:
            fail('SUPPORT_PAYOUT_NOT_STARTED')
        def final():
            fresh()
            self.service._held(state,self.claims,self.token,evidence=self.evidence)
        return final


class SupportPayoutService:
    def __init__(self, payout, settings):
        self.payout,self.factory,self.settings=payout,payout.factory,settings
        self.order_access=SupportOrderSessionAuthorizer(settings,self.factory,payout.clock)

    def _state(self, session, order):
        state=session.get(SupportPayoutState,order.id,with_for_update=True)
        quote=session.get(ManualPayoutQuote,order.quote_id)
        if state is None or quote.snapshot.get('approval_policy')!='SUPPORT_MANUAL_V1':
            fail('SUPPORT_PAYOUT_NOT_FOUND',404)
        return state

    def _held(self,state,claims,token,*,evidence=False):
        now=self.payout._now()
        if state is None or not token or state.claimed_by!=claims['sub'] or not secrets.compare_digest(state.claim_token or '',token):
            fail('SUPPORT_PAYOUT_CLAIM_REQUIRED',403)
        if not evidence and not state.review_authorized_at and (now>=utc(state.expires_at) or state.review_required):
            fail('SUPPORT_PAYOUT_EXPIRED')
        if not evidence and (state.claim_expires_at is None or now>=utc(state.claim_expires_at)):
            fail('SUPPORT_PAYOUT_CLAIM_EXPIRED')
        if evidence and state.execution_started_at is None:
            fail('SUPPORT_PAYOUT_NOT_STARTED')

    def _view(self,session,row,actor):
        return self.payout._result(row) | support_payout_projection(session,row,self.payout._now(),actor)

    def expire_orders(self, *, limit=100):
        return expire_support_payout_orders(self.factory,now=self.payout._now(),limit=limit)

    def detail(self, *, claims, order_id):
        with self.factory.begin() as session:
            fresh=self.order_access.authorization(claims=claims)(session)
            row=session.get(ManualPayoutOrder,order_id)
            if row is None: fail('SUPPORT_PAYOUT_NOT_FOUND',404)
            self._state(session,row)
            result=self._view(session,row,claims['sub'])
            fresh()
            return result

    def list(self, *, claims, limit=50, cursor=None):
        if type(limit) is not int or not 1<=limit<=100: fail('SUPPORT_PAYOUT_QUERY_INVALID',422)
        with self.factory.begin() as session:
            self.order_access.authorization(claims=claims)(session)()
        self.expire_orders()
        with self.factory.begin() as session:
            fresh=self.order_access.authorization(claims=claims)(session)
            query=select(ManualPayoutOrder).join(SupportPayoutState,SupportPayoutState.order_id==ManualPayoutOrder.id)
            if cursor:
                previous=session.get(ManualPayoutOrder,cursor)
                if previous is None: fail('SUPPORT_PAYOUT_QUERY_INVALID',422)
                query=query.where((ManualPayoutOrder.created_at<previous.created_at)|
                    ((ManualPayoutOrder.created_at==previous.created_at)&(ManualPayoutOrder.id<previous.id)))
            rows=session.scalars(query.order_by(ManualPayoutOrder.created_at.desc(),ManualPayoutOrder.id.desc()).limit(limit+1)).all()
            result={'items':[self._view(session,row,claims['sub']) for row in rows[:limit]],'next_cursor':rows[limit-1].id if len(rows)>limit else None}
            fresh()
            return result

    def claim(self, *, claims, order_id, idempotency_key):
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            state=self._state(session,row)
            fresh=self.order_access.authorization(claims=claims)(session)
            now=self.payout._now()
            if row.status!='REQUESTED' or state.execution_started_at: fail('SUPPORT_PAYOUT_ALREADY_STARTED')
            if now>=utc(state.expires_at) or state.review_required: fail('SUPPORT_PAYOUT_EXPIRED')
            payload={'order_id':order_id}
            replay=self.payout._replay(session,claims['sub'],'SUPPORT_CLAIM',idempotency_key,payload)
            if replay:
                self._held(state,claims,replay.get('claim_token'))
                fresh()
                return self._view(session,row,claims['sub'])
            if state.claimed_by and now<utc(state.claim_expires_at): fail('SUPPORT_PAYOUT_ALREADY_CLAIMED')
            state.claimed_by,state.claim_token=claims['sub'],secrets.token_urlsafe(32)
            state.claim_expires_at=min(now+timedelta(minutes=5),utc(state.expires_at))
            state.version+=1
            result=self._view(session,row,claims['sub'])
            self.payout._record(session,claims['sub'],'SUPPORT_CLAIM',idempotency_key,payload,result,now)
            fresh()
            return result

    def heartbeat(self, *, claims, order_id, claim_token):
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            state=self._state(session,row)
            fresh=self.order_access.authorization(claims=claims)(session)
            self._held(state,claims,claim_token)
            if row.status in ('SETTLED','CANCELLED','UNKNOWN'): fail('SUPPORT_PAYOUT_UNAVAILABLE')
            deadline=self.payout._now()+timedelta(minutes=5)
            state.claim_expires_at=deadline if state.review_authorized_at else min(deadline,utc(state.expires_at))
            audit_write(session,claims['sub'],order_id,'wallet.support_payout_heartbeat','SUPPORT_PAYOUT_HEARTBEAT')
            fresh()
            return self._view(session,row,claims['sub'])

    def review_claim(self, *, claims, order_id, reason_code, idempotency_key):
        if not isinstance(reason_code,str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{2,79}',reason_code):
            fail('SUPPORT_PAYOUT_REVIEW_REASON_REQUIRED',422)
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            state=self._state(session,row)
            fresh=self.order_access.authorization(claims=claims)(session)
            now=self.payout._now()
            if row.status!='REQUESTED' or state.execution_started_at or row.candidate_txid:
                fail('SUPPORT_PAYOUT_ALREADY_STARTED')
            if now<utc(state.expires_at): fail('SUPPORT_PAYOUT_REVIEW_NOT_REQUIRED')
            payload={'order_id':order_id,'reason_code':reason_code}
            replay=self.payout._replay(session,claims['sub'],'SUPPORT_REVIEW_CLAIM',idempotency_key,payload)
            if replay:
                self._held(state,claims,replay.get('claim_token'))
                fresh()
                return self._view(session,row,claims['sub'])
            if state.claimed_by and state.claim_expires_at and now<utc(state.claim_expires_at):
                fail('SUPPORT_PAYOUT_ALREADY_CLAIMED')
            state.claimed_by,state.claim_token=claims['sub'],secrets.token_urlsafe(32)
            state.claim_expires_at=now+timedelta(minutes=5)
            state.review_required=True
            state.review_authorized_at=now
            state.version+=1
            result=self._view(session,row,claims['sub'])
            self.payout._record(session,claims['sub'],'SUPPORT_REVIEW_CLAIM',idempotency_key,payload,result,now,reason_code=reason_code)
            fresh()
            return result

    def begin_payment(self, *, claims, order_id, claim_token, expected_digest, idempotency_key):
        authorize=_PayoutAuthorization(self,claims,order_id,claim_token,begin=True)
        view=self.detail(claims=claims,order_id=order_id)
        if view['execution_started_at']:
            result=self.payout.payment_instructions(admin_id=claims['sub'],order_id=order_id,
                expected_digest=expected_digest,authorize=authorize)
            return result | self.detail(claims=claims,order_id=order_id)
        result=self.payout.claim(admin_id=claims['sub'],session_id=claims['family_id'],order_id=order_id,
            expected_digest=expected_digest,idempotency_key=idempotency_key,authorize=authorize)
        return result | self.detail(claims=claims,order_id=order_id)

    def adjust_rate(self, *, claims, order_id, claim_token, new_rate, reason_code, idempotency_key):
        view=self.detail(claims=claims,order_id=order_id)
        if not view['execution_started_at']:
            self.begin_payment(claims=claims,order_id=order_id,claim_token=claim_token,expected_digest=view['digest'],
                idempotency_key='rate-begin:'+sha256(idempotency_key.encode()).hexdigest())
        self.payout.adjust_rate(admin_id=claims['sub'],session_id=claims['family_id'],order_id=order_id,new_rate=new_rate,
            reason_code=reason_code,idempotency_key=idempotency_key,authorize=_PayoutAuthorization(self,claims,order_id,claim_token))
        return self.detail(claims=claims,order_id=order_id)

    def submit_txid(self, *, claims, order_id, claim_token, txid, idempotency_key):
        self.payout.submit_txid(admin_id=claims['sub'],order_id=order_id,txid=txid,idempotency_key=idempotency_key,
            authorize=_PayoutAuthorization(self,claims,order_id,claim_token,evidence=True))
        return self.detail(claims=claims,order_id=order_id)

    def correct_candidate(self, *, claims, order_id, claim_token, txid, reason_code, idempotency_key):
        self.payout.correct_candidate(admin_id=claims['sub'],session_id=claims['family_id'],order_id=order_id,
            txid=txid,reason_code=reason_code,idempotency_key=idempotency_key,
            authorize=_PayoutAuthorization(self,claims,order_id,claim_token,evidence=True))
        return self.detail(claims=claims,order_id=order_id)

    def reconcile(self, *, claims, order_id, claim_token):
        authorize=_PayoutAuthorization(self,claims,order_id,claim_token,evidence=True)
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            self._state(session,row)
            authorize(session)()
        self.payout.reconcile(order_id=order_id,authorize=authorize)
        return self.detail(claims=claims,order_id=order_id)
