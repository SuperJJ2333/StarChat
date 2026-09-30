"""Support-order coordination over the existing payout financial engine."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4
from types import SimpleNamespace
import secrets
import re
import time
import hashlib

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, Numeric, String, UniqueConstraint, event, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.integrations.tron.finality import (
    MANUAL_SOLID_HEAD_MAX_AGE_SECONDS, NETWORK, TronEvidenceUnavailable, transaction_evidence_fresh,
)
from app.integrations.tron.reader import TronReadError, USDT_CONTRACT
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole
from app.modules.identity.support_order_auth import SupportOrderSessionAuthorizer
from app.modules.wallet.manual_payout_models import ManualPayoutEvent, ManualPayoutOrder, ManualPayoutQuote
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
    prepared_rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6))
    prepared_receive: Mapped[Decimal | None] = mapped_column(Numeric(30, 6))
    prepared_digest: Mapped[str | None] = mapped_column(String(64))
    prepared_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default='0')
    evidence_actor_id: Mapped[str | None] = mapped_column(String(36))
    evidence_token_hash: Mapped[str | None] = mapped_column(String(64))
    evidence_version: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default='0')


class SupportPayoutRatePreparation(Base):
    __tablename__ = 'wallet_support_payout_rate_preparations'
    __table_args__ = (UniqueConstraint('order_id', 'version', name='uq_support_payout_preparation_version'),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_orders.id'), nullable=False)
    version: Mapped[int] = mapped_column(Integer, nullable=False)
    rate: Mapped[Decimal] = mapped_column(Numeric(20, 6), nullable=False)
    receive: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(80), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class SupportPayoutRejection(Base):
    __tablename__ = 'wallet_support_payout_rejections'
    __table_args__ = (UniqueConstraint('order_id', name='uq_support_payout_rejection_order'),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    order_id: Mapped[str] = mapped_column(ForeignKey('wallet_manual_payout_orders.id'), nullable=False)
    actor_id: Mapped[str] = mapped_column(String(36), nullable=False)
    reason_code: Mapped[str] = mapped_column(String(80), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def _reject_history_mutation(*_args, **_kwargs) -> None:
    raise ValueError('support payout decision history is append-only')


for _history_model in (SupportPayoutRatePreparation, SupportPayoutRejection):
    event.listen(_history_model, 'before_update', _reject_history_mutation)
    event.listen(_history_model, 'before_delete', _reject_history_mutation)


@event.listens_for(Session, 'do_orm_execute')
def _reject_bulk_history_mutation(execute_state) -> None:
    if not (execute_state.is_update or execute_state.is_delete):
        return
    table = getattr(execute_state.statement, 'table', None)
    if table is not None and table.name in {
        SupportPayoutRatePreparation.__tablename__, SupportPayoutRejection.__tablename__,
    }:
        _reject_history_mutation()


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def _masked_address(address):
    if len(address) <= 12:
        return '…'
    return address[:6] + '…' + address[-6:]


def _without_target_address(result):
    if 'instructions' not in result:
        return result
    return dict(result, instructions={key: value for key, value in result['instructions'].items()
        if key != 'target_address'})


def support_payout_projection(session, row, now, actor=None):
    state = session.get(SupportPayoutState, row.id)
    if state is None:
        return {}
    quote = session.get(ManualPayoutQuote, row.quote_id)
    if row.status == 'SETTLED':
        stage = 'COMPLETED'
    elif row.status == 'CANCELLED':
        rejected = session.scalar(select(SupportPayoutRejection.id).where(
            SupportPayoutRejection.order_id == row.id)) is not None
        stage = 'REJECTED' if rejected else 'CANCELLED'
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
        prepared_rate=format(state.prepared_rate, '.6f') if state.prepared_rate is not None else None,
        prepared_receive=format(state.prepared_receive, '.6f') if state.prepared_receive is not None else None,
        prepared_digest=state.prepared_digest,prepared_version=state.prepared_version,
        target_address_masked=_masked_address(quote.snapshot['target_address']),
        claim_version=state.version,evidence_version=state.evidence_version,
        **({'claim_token':state.claim_token} if actor and state.claimed_by==actor and not state.evidence_actor_id
            and row.status not in ('CANCELLED','SETTLED') else {}))


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

    def __init__(self, service, claims, order_id, claim_token, *, begin=False, prepare=False, evidence=False,
                 expected_version=None):
        self.service,self.claims,self.order_id,self.token = service,claims,order_id,claim_token
        self.begin,self.prepare,self.evidence=begin,prepare,evidence
        self.expected_version=expected_version

    def __call__(self, session):
        fresh = self.service.order_access.authorization(claims=self.claims)(session)
        state=session.get(SupportPayoutState,self.order_id,with_for_update=True)
        self.service._held(state,self.claims,self.token,evidence=self.evidence)
        if self.expected_version is not None and state.version != self.expected_version:
            fail('SUPPORT_PAYOUT_CLAIM_VERSION_CONFLICT')
        row=session.get(ManualPayoutOrder,self.order_id)
        if row is None or row.status=='CANCELLED': fail('SUPPORT_PAYOUT_UNAVAILABLE')
        if self.prepare and (state.execution_started_at is not None or row.status!='REQUESTED' or row.candidate_txid):
            fail('SUPPORT_PAYOUT_ALREADY_STARTED')
        if not self.begin and not self.prepare and state.execution_started_at is None:
            fail('SUPPORT_PAYOUT_NOT_STARTED')
        def final():
            fresh()
            self.service._held(state,self.claims,self.token,evidence=self.evidence)
        return final


class SupportPayoutService:
    _MAX_DISCOVERY_RECEIPTS = 20
    _DISCOVERY_EVIDENCE_SECONDS = 20

    def __init__(self, payout, settings, *, discovery_reader_factory=None):
        self.payout,self.factory,self.settings=payout,payout.factory,settings
        self.order_access=SupportOrderSessionAuthorizer(settings,self.factory,payout.clock)
        self.discovery_reader_factory=discovery_reader_factory

    def _state(self, session, order):
        state=session.get(SupportPayoutState,order.id,with_for_update=True)
        quote=session.get(ManualPayoutQuote,order.quote_id)
        if state is None or quote.snapshot.get('approval_policy')!='SUPPORT_MANUAL_V1':
            fail('SUPPORT_PAYOUT_NOT_FOUND',404)
        return state

    def _held(self,state,claims,token,*,evidence=False):
        now=self.payout._now()
        if state is not None and state.evidence_actor_id:
            if (not evidence or state.evidence_actor_id != claims['sub'] or not token
                    or not secrets.compare_digest(state.evidence_token_hash or '', hashlib.sha256(token.encode()).hexdigest())):
                fail('SUPPORT_PAYOUT_CLAIM_REQUIRED',403)
            if state.execution_started_at is None:
                fail('SUPPORT_PAYOUT_NOT_STARTED')
            return
        if state is None or not token or state.claimed_by!=claims['sub'] or not secrets.compare_digest(state.claim_token or '',token):
            fail('SUPPORT_PAYOUT_CLAIM_REQUIRED',403)
        if not evidence and not state.review_authorized_at and (now>=utc(state.expires_at) or state.review_required):
            fail('SUPPORT_PAYOUT_EXPIRED')
        if not evidence and (state.claim_expires_at is None or now>=utc(state.claim_expires_at)):
            fail('SUPPORT_PAYOUT_CLAIM_EXPIRED')
        if evidence and state.execution_started_at is None:
            fail('SUPPORT_PAYOUT_NOT_STARTED')

    def _view(self,session,row,actor):
        result=self.payout._result(row) | support_payout_projection(session,row,self.payout._now(),actor)
        state=session.get(SupportPayoutState,row.id)
        now=self.payout._now()
        owner=actor == self.settings.wallet_manual_owner_admin_id and session.scalar(select(UserRole.id).where(
            UserRole.user_id==actor,UserRole.role_code==RoleCode.SUPER_ADMIN)) is not None
        live=row.status not in ('CANCELLED','SETTLED')
        leased=bool(state.claimed_by and state.claim_expires_at and now<utc(state.claim_expires_at))
        expired=now>=utc(state.expires_at) or state.review_required
        own=state.claimed_by==actor and leased and not state.evidence_actor_id
        evidence_actor=state.evidence_actor_id or state.claimed_by
        result.update(can_claim=bool(live and row.status=='REQUESTED' and not state.execution_started_at
                and not leased and not expired),
            can_takeover=bool(owner and live and state.claimed_by and (state.execution_started_at or not expired)),
            can_begin=bool(live and own and row.status=='REQUESTED' and not state.execution_started_at
                and (not expired or state.review_authorized_at)),
            can_evidence=bool(live and state.execution_started_at and evidence_actor==actor),
            owner_proof_required=bool(owner),evidence_actor_id=state.evidence_actor_id)
        return result

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

    def begin_payment(self, *, claims, order_id, claim_token, expected_digest,
                      expected_preparation_version=None, idempotency_key):
        authorize=_PayoutAuthorization(self,claims,order_id,claim_token,begin=True)
        view=self.detail(claims=claims,order_id=order_id)
        if view['execution_started_at']:
            result=self.payout.payment_instructions(admin_id=claims['sub'],order_id=order_id,
                expected_digest=expected_digest,expected_preparation_version=expected_preparation_version,
                authorize=authorize)
            return _without_target_address(result) | self.detail(claims=claims,order_id=order_id)
        result=self.payout.claim(admin_id=claims['sub'],session_id=claims['family_id'],order_id=order_id,
            expected_digest=expected_digest,expected_preparation_version=expected_preparation_version,
            idempotency_key=idempotency_key,authorize=authorize)
        return _without_target_address(result) | self.detail(claims=claims,order_id=order_id)

    def _owner_address_access(self, session, claims):
        if claims['sub'] != self.settings.wallet_manual_owner_admin_id:
            fail('SUPPORT_PAYOUT_CLAIM_REQUIRED', 403)
        roles = set(session.scalars(select(UserRole.role_code).where(
            UserRole.user_id == claims['sub']).with_for_update()))
        if RoleCode.SUPER_ADMIN not in roles:
            fail('PERMISSION_DENIED', 403)

    def takeover_receipt(self, *, claims, order_id, expected_claim_version, reason_code, idempotency_key):
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            state=self._state(session,row)
            fresh=self.order_access.authorization(claims=claims)(session)
            self._owner_address_access(session,claims)
            payload=dict(order_id=order_id,expected_claim_version=expected_claim_version,reason_code=reason_code)
            result=self.payout._replay(session,claims['sub'],'SUPPORT_TAKEOVER',idempotency_key,payload)
            if result:
                token=result.get('evidence_token') or result.get('claim_token')
                self._held(state,claims,token,evidence=bool(result.get('evidence_token')))
            fresh()
            return result

    def takeover(self, *, claims, order_id, expected_claim_version, reason_code, idempotency_key,
                 owner_authorize=None):
        if not isinstance(reason_code,str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{2,79}',reason_code):
            fail('SUPPORT_PAYOUT_TAKEOVER_REASON_REQUIRED',422)
        if type(expected_claim_version) is not int or expected_claim_version<0:
            fail('SUPPORT_PAYOUT_CLAIM_VERSION_CONFLICT',422)
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            state=self._state(session,row)
            fresh=self.order_access.authorization(claims=claims)(session)
            self._owner_address_access(session,claims)
            payload=dict(order_id=order_id,expected_claim_version=expected_claim_version,reason_code=reason_code)
            replay=self.payout._replay(session,claims['sub'],'SUPPORT_TAKEOVER',idempotency_key,payload)
            if replay:
                self._held(state,claims,replay.get('evidence_token') or replay.get('claim_token'),
                    evidence=bool(replay.get('evidence_token')))
                fresh()
                return replay
            if owner_authorize is None:
                fail('SUPPORT_OWNER_PROOF_REQUIRED',403)
            owner_fresh=owner_authorize(session)
            if state.version!=expected_claim_version:
                fail('SUPPORT_PAYOUT_CLAIM_VERSION_CONFLICT')
            if not state.claimed_by or row.status in ('CANCELLED','SETTLED'):
                fail('SUPPORT_PAYOUT_UNAVAILABLE')
            now=self.payout._now()
            previous_actor=state.evidence_actor_id or state.claimed_by
            token=secrets.token_urlsafe(32)
            if state.execution_started_at:
                state.evidence_actor_id=claims['sub']
                state.evidence_token_hash=hashlib.sha256(token.encode()).hexdigest()
                state.evidence_version+=1
            else:
                if row.status!='REQUESTED' or row.candidate_txid:
                    fail('SUPPORT_PAYOUT_UNAVAILABLE')
                if now>=utc(state.expires_at) or state.review_required:
                    fail('SUPPORT_PAYOUT_EXPIRED')
                state.claimed_by,state.claim_token=claims['sub'],token
                state.claim_expires_at=min(now+timedelta(minutes=5),utc(state.expires_at))
            state.version+=1
            result=self._view(session,row,claims['sub'])
            if state.execution_started_at:
                result['evidence_token']=token
            self.payout._record(session,claims['sub'],'SUPPORT_TAKEOVER',idempotency_key,payload,result,now,
                reason_code=reason_code)
            OutboxPublisher.enqueue(session,topic='wallet',event_type='wallet.support_payout_taken_over',
                aggregate_type='manual_payout_order',aggregate_id=order_id,
                payload=dict(order_id=order_id,actor_id=claims['sub'],previous_actor_id=previous_actor,
                    reason_code=reason_code,evidence_only=bool(state.execution_started_at)),now=now)
            fresh()
            owner_fresh()
            self._owner_address_access(session,claims)
            return result

    def _evidence_access(self, session, state, claims, claim_token):
        if claim_token is None:
            self._owner_address_access(session, claims)
        else:
            self._held(state, claims, claim_token, evidence=True)

    def read_payment_address(self, *, claims, order_id, claim_token=None):
        with self.factory.begin() as session:
            row, _ = self.payout._order_lock(session, order_id)
            state = self._state(session, row)
            fresh = self.order_access.authorization(claims=claims)(session)
            if state.execution_started_at is None or row.status not in ('CLAIMED', 'UNKNOWN', 'SETTLED'):
                fail('SUPPORT_PAYOUT_NOT_STARTED')
            self._evidence_access(session, state, claims, claim_token)
            quote = session.get(ManualPayoutQuote, row.quote_id)
            result = {'target_address': quote.snapshot['target_address'], 'network': 'TRON'}
            audit_write(session, claims['sub'], order_id,
                'wallet.support_payout_address_read', 'SUPPORT_PAYOUT_ADDRESS_READ')
            fresh()
            self._evidence_access(session, state, claims, claim_token)
            return result

    def _discovery_snapshot(self, session, *, claims, order_id, claim_token):
        row, _ = self.payout._order_lock(session, order_id)
        state = self._state(session, row)
        fresh = self.order_access.authorization(claims=claims)(session)
        if state.execution_started_at is None or row.status not in ('CLAIMED', 'UNKNOWN'):
            fail('SUPPORT_PAYOUT_NOT_STARTED')
        self._evidence_access(session, state, claims, claim_token)
        quote = session.get(ManualPayoutQuote, row.quote_id)
        if row.claimed_at is None or quote.digest != row.digest:
            fail('SUPPORT_PAYOUT_DISCOVERY_CONFLICT')
        snapshot = dict(status=row.status, state_version=state.version,
            evidence_version=state.evidence_version, digest=row.adjusted_digest or row.digest,
            official_address=quote.snapshot['official_address'],
            target_address=quote.snapshot['target_address'],
            amount_units=int(self.payout._payable(row, quote) * 1000000),
            start_ms=int(utc(row.claimed_at).timestamp() * 1000))
        fresh()
        self._evidence_access(session, state, claims, claim_token)
        return snapshot, row, quote

    def discover(self, *, claims, order_id, claim_token=None):
        """Find verified candidate IDs without saving a locator or changing payout state."""
        with self.factory.begin() as session:
            snapshot, _, _ = self._discovery_snapshot(session, claims=claims,
                order_id=order_id, claim_token=claim_token)
        end_ms = int((self.payout._now()-timedelta(
            seconds=MANUAL_SOLID_HEAD_MAX_AGE_SECONDS)).timestamp() * 1000)
        status, candidates = 'EMPTY', []
        if end_ms < snapshot['start_ms']:
            status = 'INCOMPLETE'
        elif self.discovery_reader_factory is None or self.payout.finality is None:
            status = 'UNAVAILABLE'
        else:
            reader = None
            try:
                reader = self.discovery_reader_factory()
                txids = reader.discover_transaction_ids(snapshot['official_address'],
                    snapshot['start_ms'], end_ms)
                if (not isinstance(txids, list) or len(txids) > self._MAX_DISCOVERY_RECEIPTS
                        or any(not isinstance(txid, str) or re.fullmatch(r'[0-9a-fA-F]{64}', txid) is None
                            for txid in txids)):
                    status = 'INCOMPLETE'
                else:
                    deadline = time.monotonic() + self._DISCOVERY_EVIDENCE_SECONDS
                    for txid in dict.fromkeys(txids):
                        if time.monotonic() >= deadline:
                            status = 'INCOMPLETE'
                            break
                        try:
                            observed = self.payout.finality.transaction_evidence(txid)
                        except TronEvidenceUnavailable:
                            status = 'INCOMPLETE'
                            break
                        if time.monotonic() >= deadline:
                            status = 'INCOMPLETE'
                            break
                        if not transaction_evidence_fresh(observed, self.payout._now()):
                            status = 'INCOMPLETE'
                            break
                        # The common payout matcher requires the immutable exact
                        # amount, sender, recipient, contract, and settled receipt.
                        with self.factory() as session:
                            row = session.get(ManualPayoutOrder, order_id)
                            quote = session.get(ManualPayoutQuote, row.quote_id)
                            matches = self.payout.matching_payout_transfers(observed, row, quote, txid)
                        for transfer in matches:
                            if not snapshot['start_ms'] <= transfer.timestamp_ms <= end_ms:
                                continue
                            candidates.append(dict(txid=txid, log_index=transfer.log_index,
                                timestamp_ms=transfer.timestamp_ms,
                                amount=format(Decimal(transfer.amount_units)/Decimal(1000000), '.6f'),
                                masked_target_address=_masked_address(snapshot['target_address']),
                                evidence_status='VERIFIED'))
                    if status == 'EMPTY':
                        status = 'COMPLETE' if candidates else 'EMPTY'
            except TronReadError as error:
                status = 'UNAVAILABLE' if 'request failed' in str(error).lower() else 'INCOMPLETE'
            except RuntimeError:
                status = 'UNAVAILABLE'
            finally:
                if reader is not None:
                    reader.close()
        if status not in ('COMPLETE', 'EMPTY'):
            candidates = []
        with self.factory.begin() as session:
            current, row, quote = self._discovery_snapshot(session, claims=claims,
                order_id=order_id, claim_token=claim_token)
            if current != snapshot:
                fail('SUPPORT_PAYOUT_DISCOVERY_CONFLICT')
            for candidate in candidates:
                used = session.scalar(select(ManualPayoutEvent.id).where(
                    ManualPayoutEvent.network == NETWORK,
                    ManualPayoutEvent.contract == USDT_CONTRACT,
                    ManualPayoutEvent.txid == candidate['txid'],
                    ManualPayoutEvent.log_index == candidate['log_index']))
                if used is not None:
                    candidate['evidence_status'] = 'CONFLICT'
                elif not self.payout._require_unambiguous_owner(session,row,quote,SimpleNamespace(
                        timestamp_ms=candidate['timestamp_ms'],from_address=snapshot['official_address'],
                        to_address=snapshot['target_address'],amount_units=snapshot['amount_units'])):
                    candidate['evidence_status']='AMBIGUOUS'
                    audit_write(session,claims['sub'],row.id,'wallet.support_payout_discovery_ambiguous',
                        'ORDER_ATTRIBUTION_AMBIGUOUS')
            audit_write(session, claims['sub'], row.id,
                'wallet.support_payout_discovery_read', 'SUPPORT_PAYOUT_DISCOVERY_READ')
            self.order_access.authorization(claims=claims)(session)()
            self._evidence_access(session, session.get(SupportPayoutState, order_id), claims, claim_token)
        return dict(status=status, candidates=candidates,
            window_start_ms=snapshot['start_ms'], window_end_ms=end_ms,
            claim_version=snapshot['state_version'],evidence_version=snapshot['evidence_version'],
            manual_txid_fallback=True)

    def select_discovered(self, *, claims, order_id, claim_token, txid, log_index,
                          expected_claim_version, idempotency_key):
        if type(log_index) is not int or log_index<0:
            fail('SUPPORT_PAYOUT_CANDIDATE_INVALID',422)
        if not isinstance(txid,str) or not re.fullmatch(r'[0-9a-fA-F]{64}',txid):
            fail('SUPPORT_PAYOUT_CANDIDATE_INVALID',422)
        payload=dict(order_id=order_id,txid=txid.lower(),log_index=log_index,
            expected_claim_version=expected_claim_version)
        authorize=_PayoutAuthorization(self,claims,order_id,claim_token,evidence=True,
            expected_version=expected_claim_version)
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            authorize(session)()
            replay=self.payout._replay(session,claims['sub'],'SUPPORT_SELECT',idempotency_key,payload)
            if replay:
                return replay
        found=self.discover(claims=claims,order_id=order_id,claim_token=claim_token)
        if found['claim_version']!=expected_claim_version:
            fail('SUPPORT_PAYOUT_CLAIM_VERSION_CONFLICT')
        candidates=[item for item in found['candidates'] if item['txid']==txid.lower()
            and item['log_index']==log_index and item['evidence_status']=='VERIFIED']
        if any(item['txid']==txid.lower() and item['log_index']==log_index
                and item['evidence_status']=='AMBIGUOUS' for item in found['candidates']):
            fail('SUPPORT_PAYOUT_ORDER_ATTRIBUTION_AMBIGUOUS')
        if found['status']!='COMPLETE' or len(candidates)!=1:
            fail('SUPPORT_PAYOUT_CANDIDATE_UNAVAILABLE')
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            authorize(session)()
            quote=session.get(ManualPayoutQuote,row.quote_id)
            transfer=SimpleNamespace(timestamp_ms=candidates[0]['timestamp_ms'],
                from_address=quote.snapshot['official_address'],to_address=quote.snapshot['target_address'],
                amount_units=int(self.payout._payable(row,quote)*1000000))
            if not self.payout._require_unambiguous_owner(session,row,quote,transfer):
                fail('SUPPORT_PAYOUT_ORDER_ATTRIBUTION_AMBIGUOUS')
            current=row.candidate_txid
        if current is not None and current!=txid.lower():
            self.payout.correct_candidate(admin_id=claims['sub'],session_id=claims['family_id'],order_id=order_id,
                txid=txid,reason_code='DISCOVERED_LOCATOR_SELECTED',idempotency_key=idempotency_key,authorize=authorize)
        else:
            self.payout.submit_txid(admin_id=claims['sub'],order_id=order_id,txid=txid,
                idempotency_key=idempotency_key,authorize=authorize)
        self.payout.reconcile(order_id=order_id,authorize=authorize)
        with self.factory.begin() as session:
            row,_=self.payout._order_lock(session,order_id)
            fresh=authorize(session)
            result=self._view(session,row,claims['sub'])
            replay=self.payout._replay(session,claims['sub'],'SUPPORT_SELECT',idempotency_key,payload)
            if replay:
                fresh()
                return replay
            self.payout._record(session,claims['sub'],'SUPPORT_SELECT',idempotency_key,payload,
                result,self.payout._now(),reason_code='DISCOVERED_LOCATOR_SELECTED')
            fresh()
            return result

    def adjust_rate(self, *, claims, order_id, claim_token, new_rate, reason_code,
                    expected_preparation_version=None, idempotency_key):
        self.payout.prepare_support_rate(admin_id=claims['sub'],order_id=order_id,new_rate=new_rate,
            reason_code=reason_code,expected_preparation_version=expected_preparation_version,
            idempotency_key=idempotency_key,
            authorize=_PayoutAuthorization(self,claims,order_id,claim_token,prepare=True))
        return self.detail(claims=claims,order_id=order_id)

    def _rejection_receipt(self, session, *, state, actor_id, order_id, claim_token,
                           reason_code, idempotency_key):
        payload = {'order_id': order_id, 'claim_token': claim_token, 'reason_code': reason_code}
        replay = self.payout._replay(session, actor_id, 'SUPPORT_REJECT', idempotency_key, payload)
        if replay:
            decision = session.scalar(select(SupportPayoutRejection).where(
                SupportPayoutRejection.order_id == order_id))
            if (decision is None or decision.actor_id != actor_id or decision.reason_code != reason_code
                    or state.claimed_by != actor_id or not claim_token
                    or not secrets.compare_digest(state.claim_token or '', claim_token)):
                fail('SUPPORT_PAYOUT_CLAIM_REQUIRED', 403)
        return replay, payload

    def rejection_receipt(self, *, claims, order_id, claim_token, reason_code, idempotency_key):
        """Read an exact committed rejection before a retry consumes owner proof."""
        with self.factory.begin() as session:
            row, _ = self.payout._order_lock(session, order_id)
            state = self._state(session, row)
            fresh = self.order_access.authorization(claims=claims)(session)
            actor_id = claims['sub']
            if actor_id == self.settings.wallet_manual_owner_admin_id:
                roles = set(session.scalars(select(UserRole.role_code).where(
                    UserRole.user_id == actor_id).with_for_update()))
                if RoleCode.SUPER_ADMIN not in roles:
                    fail('PERMISSION_DENIED', 403)
            replay, _ = self._rejection_receipt(session, state=state, actor_id=actor_id,
                order_id=order_id, claim_token=claim_token, reason_code=reason_code,
                idempotency_key=idempotency_key)
            fresh()
            return replay

    def reject(self, *, claims, order_id, claim_token, reason_code, idempotency_key,
               owner_authorize=None):
        if reason_code not in {'PAYOUT_ADDRESS_INVALID', 'PAYOUT_DETAILS_MISMATCH',
                'PAYOUT_POLICY_INELIGIBLE'}:
            fail('SUPPORT_PAYOUT_REJECTION_REASON_INVALID', 422)
        with self.factory.begin() as session:
            row, _ = self.payout._order_lock(session, order_id)
            state = self._state(session, row)
            fresh = self.order_access.authorization(claims=claims)(session)
            actor_id = claims['sub']
            owner_id = self.settings.wallet_manual_owner_admin_id
            if actor_id == owner_id:
                roles = set(session.scalars(select(UserRole.role_code).where(
                    UserRole.user_id == actor_id).with_for_update()))
                if RoleCode.SUPER_ADMIN not in roles:
                    fail('PERMISSION_DENIED', 403)
            elif owner_authorize is not None:
                fail('SUPPORT_OWNER_PROOF_NOT_ALLOWED', 403)
            replay, payload = self._rejection_receipt(session, state=state, actor_id=actor_id,
                order_id=order_id, claim_token=claim_token, reason_code=reason_code,
                idempotency_key=idempotency_key)
            if replay:
                fresh()
                return replay
            owner_fresh = None
            if actor_id == owner_id:
                if owner_authorize is None:
                    fail('SUPPORT_OWNER_PROOF_REQUIRED', 403)
                owner_fresh = owner_authorize(session)
            self._held(state, claims, claim_token)
            if row.status != 'REQUESTED' or state.execution_started_at is not None or row.candidate_txid:
                fail('SUPPORT_PAYOUT_ALREADY_STARTED')
            now = self.payout._now()
            self.payout.release_unstarted_order(session=session, row=row, actor_id=actor_id,
                reason_code='MANUAL_PAYOUT_REJECTED', now=now)
            session.add(SupportPayoutRejection(id=str(uuid4()), order_id=order_id,
                actor_id=actor_id, reason_code=reason_code, created_at=now))
            session.flush()
            result = self._view(session, row, actor_id)
            self.payout._record(session, actor_id, 'SUPPORT_REJECT', idempotency_key,
                payload, result, now, reason_code=reason_code)
            OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.support_payout_rejected',
                aggregate_type='manual_payout_order', aggregate_id=order_id,
                payload={'order_id': order_id, 'actor_id': actor_id, 'reason_code': reason_code}, now=now)
            fresh()
            if owner_fresh is not None:
                owner_fresh()
            self._held(state, claims, claim_token)
            return result

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
