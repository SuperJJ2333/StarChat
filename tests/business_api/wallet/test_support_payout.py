from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from test_manual_payouts import core, quote, request, evidence
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import User, UserRole, Device, RefreshTokenFamily, AdminSession
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.staff_activation import StaffActivation, staff_identity
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.support_payout import SupportPayoutRatePreparation, SupportPayoutState
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.fx.models import FxRate


def test_new_payout_policy_is_explicitly_support_scoped(core):
    core[0].support_orders_enabled=True
    assert quote(core)['approval_policy']=='SUPPORT_MANUAL_V1'


@pytest.fixture
def scoped(core):
    from app.modules.wallet.support_payout import SupportPayoutService
    svc,factory,clock,*_=core
    svc.support_orders_enabled=True
    claims={}
    settings=SimpleNamespace(wallet_admin_auth_mode='operation_password',wallet_manual_owner_admin_id='owner',
        wallet_real_mode='manual_tron',wallet_access_grant_enabled=True)
    for uid in ('owner','bob'):
        with factory.begin() as session:
            user=session.get(User,uid)
            user.password_hash=PasswordHasher().hash('correct login password')
            user.email_verified_at=clock[0]
            if uid=='bob':
                session.add(UserRole(id='bob-finance',user_id=uid,role_code=RoleCode.FINANCE_SUPPORT,
                    assigned_by='owner',assigned_at=clock[0]))
                session.flush()
                session.add(StaffActivation(user_id=uid,identity_digest=staff_identity(session,user)[2],activated_at=clock[0]))
            session.add(Device(id=uid+'-device',user_id=uid,device_key=uid+'-browser',display_name='Browser',
                created_at=clock[0],last_seen_at=clock[0]))
            session.flush()
            session.add(RefreshTokenFamily(id=uid+'-family',user_id=uid,device_id=uid+'-device',created_at=clock[0]))
            session.flush()
            session.add(AdminSession(user_id=uid,family_id=uid+'-family',entry_mode='ADMIN' if uid=='owner' else 'STAFF',created_at=clock[0],authenticated_at=clock[0],expires_at=clock[0]+timedelta(hours=48)))
        claims[uid]=dict(sub=uid,device_id=uid+'-device',family_id=uid+'-family',session_scope='admin',
            iat=int(clock[0].timestamp()),exp=int((clock[0]+timedelta(hours=48)).timestamp()))
    return core,SupportPayoutService(svc,settings),claims


def caibi_order(scoped):
    core, service, claims = scoped
    core[0].conversions_enabled = True
    core[0].rate_provider = lambda: (Decimal('7.120000'), False, core[2][0].isoformat())
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('2000')
        session.add(FxRate(pair='USD/CNY', rate=Decimal('7.120000'), fetched_at=core[2][0],
            expires_at=core[2][0]+timedelta(hours=1), fetch_state='idle'))
    LedgerService(core[1]).adjust(user_id='alice', amount=Decimal('300.00'), actor_id='finance',
        reason_code='TEST_FUND', idempotency_key='support-caibi-fund')
    terms = quote(core, amount='142.400000', funding_asset='CAIBI', idempotency_key='caibi-quote')
    order = request(core, terms)
    lease = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='caibi-lease')
    return order, lease


def prepare(scoped, order, lease, *, rate, version, key):
    _, service, claims = scoped
    return service.adjust_rate(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], new_rate=rate, reason_code='RATE_REVIEWED',
        expected_preparation_version=version, idempotency_key=key)


def test_two_rate_preparations_preserve_original_hold_and_final_terms(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    before = (core[5].balance('alice'), core[5].balance('HOLD:alice'),
        LedgerService(core[1]).balance('alice'))
    first = prepare(scoped, order, lease, rate='8.000000', version=0, key='prepare-one')
    second = prepare(scoped, order, lease, rate='7.500000', version=1, key='prepare-two')
    assert prepare(scoped, order, lease, rate='8.000000', version=0, key='prepare-one')['prepared_version'] == 2
    with pytest.raises(AppError):
        prepare(scoped, order, lease, rate='8.100000', version=0, key='prepare-one')
    assert first['prepared_version'] == 1 and first['prepared_receive'] == '17.800000'
    assert second['prepared_version'] == 2 and second['prepared_receive'] == '18.986667'
    assert (core[5].balance('alice'), core[5].balance('HOLD:alice'),
        LedgerService(core[1]).balance('alice')) == before
    with core[1]() as session:
        from app.core.outbox import OutboxEvent
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        history = session.scalars(select(SupportPayoutRatePreparation).where(
            SupportPayoutRatePreparation.order_id == order['id']).order_by(
            SupportPayoutRatePreparation.version)).all()
        assert row.status == 'REQUESTED' and row.final_rate is None and row.final_receive is None
        assert row.adjusted_digest is None and state.execution_started_at is None
        assert [(item.version, item.actor_id) for item in history] == [(1, 'bob'), (2, 'bob')]
        assert len(session.scalars(select(OutboxEvent).where(
            OutboxEvent.event_type == 'wallet.manual_payout_rate_prepared',
            OutboxEvent.aggregate_id == order['id'])).all()) == 2


def test_preparation_version_conflict_failure_and_usdt_rate_denial(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    for version in (None, 1):
        with pytest.raises(AppError):
            prepare(scoped, order, lease, rate='8.000000', version=version, key='bad-version-'+str(version))
    with pytest.raises(AppError):
        prepare(scoped, order, lease, rate='0.000000', version=0, key='bad-rate')
    assert service.detail(claims=claims['bob'], order_id=order['id'])['execution_started_at'] is None
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    usdt = request(core, quote(core, amount='10.000000', funding_asset='USDT', idempotency_key='usdt-quote'),
        idempotency_key='usdt-request')
    usdt_lease = service.claim(claims=claims['bob'], order_id=usdt['id'], idempotency_key='usdt-lease')
    with pytest.raises(AppError):
        prepare(scoped, usdt, usdt_lease, rate='1.200000', version=0, key='usdt-rate')
    assert core[5].balance('HOLD:alice') == Decimal('30')


def test_caibi_begin_requires_latest_preparation_and_moves_hold_atomically(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    first = prepare(scoped, order, lease, rate='8.000000', version=0, key='first-rate')
    latest = prepare(scoped, order, lease, rate='7.500000', version=1, key='latest-rate')
    args = dict(claims=claims['bob'], order_id=order['id'], claim_token=lease['claim_token'])
    for digest, version in ((order['digest'], 2), (first['prepared_digest'], 1),
            (latest['prepared_digest'], None)):
        with pytest.raises(AppError):
            service.begin_payment(**args, expected_digest=digest,
                expected_preparation_version=version, idempotency_key='bad-begin-'+str(version)+digest[:8])
    assert core[5].balance('HOLD:alice') == Decimal('20')
    started = service.begin_payment(**args, expected_digest=latest['prepared_digest'],
        expected_preparation_version=2, idempotency_key='begin-current')
    assert started['status'] == 'CLAIMED' and started['instructions']['amount'] == '18.986667'
    assert core[5].balance('HOLD:alice') == Decimal('18.986667')
    assert core[5].balance('alice') == Decimal('1001.013333')
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        assert (row.final_rate, row.final_receive, row.adjusted_digest) == (
            Decimal('7.500000'), Decimal('18.986667'), latest['prepared_digest'])
        assert state.execution_started_at is not None
    assert service.begin_payment(**args, expected_digest=latest['prepared_digest'],
        expected_preparation_version=2, idempotency_key='begin-current')['instructions'] == started['instructions']


def test_started_support_order_cannot_use_legacy_rate_adjustment(scoped):
    from app.modules.wallet.support_payout import _PayoutAuthorization
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    prepared = prepare(scoped, order, lease, rate='8.000000', version=0, key='prepare-rate')
    service.begin_payment(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=prepared['prepared_digest'],
        expected_preparation_version=1, idempotency_key='begin')
    with pytest.raises(AppError):
        core[0].adjust_rate(admin_id='bob', session_id=claims['bob']['family_id'],
            order_id=order['id'], new_rate='7.500000', reason_code='RATE_REVIEWED',
            idempotency_key='legacy-adjust-after-start',
            authorize=_PayoutAuthorization(service, claims['bob'], order['id'], lease['claim_token']))
    assert core[5].balance('HOLD:alice') == Decimal('17.8')


def test_usdt_begin_uses_original_digest_and_hold_without_preparation(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='usdt-claim')
    started = service.begin_payment(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'],
        expected_preparation_version=None, idempotency_key='usdt-begin')
    assert started['status'] == 'CLAIMED' and started['instructions']['amount'] == '10.000000'
    assert core[5].balance('HOLD:alice') == Decimal('10')


def test_preparation_version_bodies_require_nonnegative_integer():
    from app.api.support_payout import BeginBody, RateBody
    common = dict(claim_token='x'*32)
    assert BeginBody(**(common | dict(expected_digest='a'*64))).expected_preparation_version is None
    assert RateBody(**(common | dict(new_rate='7.5', reason_code='RATE_REVIEWED'))).expected_preparation_version is None
    for body, fields in ((BeginBody, dict(expected_digest='a'*64)),
            (RateBody, dict(new_rate='7.5', reason_code='RATE_REVIEWED'))):
        for bad in ('1', -1, True):
            with pytest.raises(ValidationError):
                body(**(common | fields | dict(expected_preparation_version=bad)))


def test_historical_started_caibi_order_remains_readable_without_preparation(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    with core[1].begin() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        row.status, row.claimed_by, row.claimed_at = 'CLAIMED', 'bob', core[2][0]
        state.execution_started_at = core[2][0]
    read = service.begin_payment(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'],
        expected_preparation_version=None, idempotency_key='read-historical')
    assert read['status'] == 'CLAIMED' and read['instructions']['amount'] == '20.000000'
    assert core[5].balance('HOLD:alice') == Decimal('20')


def test_tampered_preparation_rate_fails_closed_before_begin(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    prepared = prepare(scoped, order, lease, rate='8.000000', version=0, key='valid-preparation')
    with core[1].begin() as session:
        session.get(SupportPayoutState, order['id']).prepared_rate = Decimal('0')
    with pytest.raises(AppError):
        service.begin_payment(claims=claims['bob'], order_id=order['id'],
            claim_token=lease['claim_token'], expected_digest=prepared['prepared_digest'],
            expected_preparation_version=1, idempotency_key='tampered-begin')
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == Decimal('20')


def test_begin_rechecks_target_binding_snapshot(scoped):
    from app.modules.wallet.binding_models import WalletBinding
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='binding-lease')
    with core[1].begin() as session:
        session.get(WalletBinding, 'binding').version = 2
    with pytest.raises(AppError):
        service.begin_payment(claims=claims['bob'], order_id=order['id'],
            claim_token=lease['claim_token'], expected_digest=order['digest'],
            expected_preparation_version=None, idempotency_key='binding-drift-begin')
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == Decimal('10')


@pytest.mark.parametrize('failure', ['insufficient', 'stale_reserve'])
def test_failed_caibi_begin_preserves_release_eligibility(scoped, failure):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    prepared = prepare(scoped, order, lease, rate='6.500000', version=0, key='higher-payable')
    if failure == 'insufficient':
        core[5].post(entries={'alice': Decimal('-1000'), 'PLATFORM_CUSTODY': Decimal('1000')},
            actor_id='alice', reason_code='TEST_DRAIN', idempotency_key='drain', scope='test')
    else:
        with core[1].begin() as session:
            session.get(RedeemabilityReserve, 'global').observed_at -= timedelta(minutes=3)
    with pytest.raises(AppError):
        service.begin_payment(claims=claims['bob'], order_id=order['id'],
            claim_token=lease['claim_token'], expected_digest=prepared['prepared_digest'],
            expected_preparation_version=1, idempotency_key='failed-begin')
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        assert row.status == 'REQUESTED' and row.final_receive is None
        assert state.execution_started_at is None
    assert core[5].balance('HOLD:alice') == Decimal('20')
    assert core[0].cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel-after-failed-begin')['status'] == 'CANCELLED'


def test_support_lease_excludes_others_and_expired_holder(scoped):
    core,svc,claims=scoped
    order=request(core)
    first=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    assert first['claim_token'] and first['status']=='REQUESTED'
    with pytest.raises(AppError): svc.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='compete')
    assert svc.detail(claims=claims['owner'],order_id=order['id']).get('claim_token') is None
    core[2][0]+=timedelta(minutes=5)
    second=svc.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='takeover')
    assert first['claim_token']!=second['claim_token']
    with pytest.raises(AppError): svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=first['claim_token'],expected_digest=order['digest'],idempotency_key='stale')


def test_begin_claims_existing_engine_then_unknown_cannot_takeover_or_cancel(scoped):
    core,svc,claims=scoped
    order=request(core)
    lease=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    started=svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin')
    assert started['status']=='CLAIMED' and started['instructions']['amount']=='10.000000'
    assert core[5].balance('HOLD:alice')==Decimal('10')
    core[2][0]+=timedelta(hours=2)
    assert svc.detail(claims=claims['bob'],order_id=order['id'])['processing_stage']=='NEEDS_REVIEW'
    with pytest.raises(AppError): core[0].cancel(user_id='alice',order_id=order['id'],idempotency_key='cancel')
    with pytest.raises(AppError): svc.claim(claims=claims['owner'],order_id=order['id'],idempotency_key='takeover')
    assert core[5].balance('HOLD:alice')==Decimal('10')


def test_expired_unstarted_order_retains_hold_until_explicit_cancel(scoped):
    core,svc,claims=scoped
    order=request(core)
    core[2][0]+=timedelta(hours=2)
    assert core[0].status(user_id='alice',order_id=order['id'])['processing_stage']=='NEEDS_REVIEW'
    with pytest.raises(AppError): svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='late')
    assert core[5].balance('HOLD:alice')==Decimal('10')
    assert core[0].cancel(user_id='alice',order_id=order['id'],idempotency_key='cancel')['status']=='CANCELLED'


def test_staff_txid_submission_does_not_settle_without_verified_evidence(scoped):
    core,svc,claims=scoped
    order=request(core)
    lease=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin')
    submitted=svc.submit_txid(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],txid='a'*64,idempotency_key='tx')
    assert submitted['status']=='UNKNOWN'
    assert svc.reconcile(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'])['status']=='UNKNOWN'
    assert core[5].balance('HOLD:alice')==Decimal('10')
    core[6].evidence=evidence(core)
    assert svc.reconcile(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'])['status']=='SETTLED'
    assert core[5].balance('HOLD:alice')==Decimal('0')


def test_legacy_owner_path_cannot_bypass_support_lease(scoped):
    core,svc,claims=scoped
    order=request(core)
    with pytest.raises(AppError,match='SUPPORT_PAYOUT_AUTHORIZATION_REQUIRED'):
        core[0].claim(admin_id='owner',session_id='owner-family',mfa_proof='123456',order_id=order['id'],
            expected_digest=order['digest'],idempotency_key='bypass')
    assert core[0].status(user_id='alice',order_id=order['id'])['status']=='REQUESTED'


def test_role_revocation_after_lease_denies_start(scoped):
    core,svc,claims=scoped
    order=request(core)
    lease=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    with core[1].begin() as session: session.delete(session.get(UserRole,'bob-finance'))
    with pytest.raises(AppError):
        svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin')
    assert core[0].status(user_id='alice',order_id=order['id'])['status']=='REQUESTED'


def test_cancel_after_lease_prevents_begin_and_releases_once(scoped):
    core,svc,claims=scoped
    order=request(core)
    lease=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    core[0].cancel(user_id='alice',order_id=order['id'],idempotency_key='cancel')
    with pytest.raises(AppError):
        svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin')
    assert core[5].balance('HOLD:alice')==Decimal('0')
    assert core[5].balance('alice')==Decimal('1000')


def test_timeout_event_is_durable_and_deduplicated_without_balance_mutation(scoped):
    from app.core.outbox import OutboxEvent
    core,svc,claims=scoped
    order=request(core)
    core[2][0]+=timedelta(hours=2)
    assert svc.expire_orders()==1
    assert svc.expire_orders()==0
    with core[1]() as session:
        events=session.scalars(select(OutboxEvent).where(OutboxEvent.event_type=='wallet.support_payout_expired')).all()
        assert len(events)==1 and events[0].aggregate_id==order['id']
    assert core[5].balance('HOLD:alice')==Decimal('10')


def test_expired_unstarted_review_claim_requires_reason_and_revalidates_digest(scoped):
    core,svc,claims=scoped
    order=request(core)
    core[2][0]+=timedelta(hours=2)
    svc.expire_orders()
    with pytest.raises(AppError):
        svc.review_claim(claims=claims['bob'],order_id=order['id'],reason_code='',idempotency_key='bad')
    lease=svc.review_claim(claims=claims['bob'],order_id=order['id'],reason_code='PAYOUT_REVIEW_CONFIRMED',idempotency_key='review')
    assert lease['processing_stage']=='REVIEWING' and lease['expires_at']==order['expires_at']
    assert svc.expire_orders()==0
    core[2][0]+=timedelta(minutes=5)
    assert svc.detail(claims=claims['bob'],order_id=order['id'])['processing_stage']=='NEEDS_REVIEW'
    lease=svc.review_claim(claims=claims['bob'],order_id=order['id'],reason_code='PAYOUT_REVIEW_RENEWED',idempotency_key='review-again')
    with core[1].begin() as session:
        session.get(RedeemabilityReserve,'global').observed_at=core[2][0]
    with pytest.raises(AppError):
        svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest='0'*64,idempotency_key='bad-digest')
    assert svc.detail(claims=claims['bob'],order_id=order['id'])['execution_started_at'] is None
    started=svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin-review')
    assert started['status']=='CLAIMED'
    core[2][0]+=timedelta(minutes=6)
    with pytest.raises(AppError):
        svc.review_claim(claims=claims['owner'],order_id=order['id'],reason_code='PAYOUT_REVIEW_CONFIRMED',idempotency_key='steal')
    assert core[5].balance('HOLD:alice')==Decimal('10')


def test_late_evidence_uses_live_session_without_reverification_and_preserves_unknown_hold(scoped):
    core,svc,claims=scoped
    order=request(core)
    lease=svc.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='claim')
    svc.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],expected_digest=order['digest'],idempotency_key='begin')
    core[2][0]+=timedelta(hours=2)
    result=svc.submit_txid(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],txid='a'*64,idempotency_key='late')
    assert result['status']=='UNKNOWN' and result['processing_stage']=='NEEDS_REVIEW'
    corrected=svc.correct_candidate(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],
        txid='b'*64,reason_code='PAYOUT_TXID_CORRECTION',idempotency_key='correct')
    assert corrected['candidate_txid']=='a'*64  # Original locator is immutable.
    assert core[5].balance('HOLD:alice')==Decimal('10')


@pytest.mark.asyncio
async def test_scoped_payout_http_contract_and_app_token_rejection(scoped):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.tokens import TokenService
    from app.api.support_payout import create_support_payout_router
    core,service,claims=scoped
    settings=Settings(_env_file=None,environment='test',jwt_secret='test-jwt-secret-at-least-thirty-two-bytes').model_copy(update=vars(service.settings))
    tokens=TokenService(core[1],jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer,now_factory=lambda:core[2][0])
    pair=tokens.issue_admin_pair(user_id='bob',display_name='Browser')
    mobile=tokens.issue_pair(user_id='bob',device_key='mobile',display_name='APP')
    order=request(core)
    app=FastAPI();install_error_handlers(app)
    app.include_router(create_support_payout_router(settings,core[1],runtime=SimpleNamespace(payouts=core[0],payout_execution_enabled=True)),prefix='/api/v1')
    async with AsyncClient(transport=ASGITransport(app=app),base_url='https://test') as client:
        path='/api/v1/admin/support-orders/payouts'
        assert (await client.get(path,headers={'Authorization':'Bearer '+mobile.access_token})).status_code==403
        headers={'Authorization':'Bearer '+pair.access_token}
        page=await client.get(path,headers=headers)
        assert page.status_code==200,page.text
        assert page.json()['items'][0]['expires_at']
        lease=await client.post(path+'/'+order['id']+'/claim',headers={**headers,'Idempotency-Key':'api-claim'},json={})
        assert lease.status_code==200,lease.text
        token=lease.json()['claim_token']
        begun=await client.post(path+'/'+order['id']+'/begin-payment',headers={**headers,'Idempotency-Key':'api-begin'},
            json={'claim_token':token,'expected_digest':order['digest']})
        assert begun.status_code==200,begun.text
        assert begun.json()['instructions']['amount']=='10.000000'


@pytest.mark.parametrize('change', ['disabled', 'unactivated', 'role', 'contact',
    'device', 'family', 'replacement', 'expired', 'app'])
def test_order_access_denies_live_identity_or_session_changes(scoped, change):
    core, service, claims = scoped
    order = request(core)
    actor = dict(claims['bob'])
    with core[1].begin() as session:
        if change == 'disabled':
            session.get(User, 'bob').status = 'DISABLED'
        elif change == 'unactivated':
            session.delete(session.get(StaffActivation, 'bob'))
        elif change == 'role':
            session.delete(session.get(UserRole, 'bob-finance'))
        elif change == 'contact':
            session.get(User, 'bob').email_normalized = 'changed@example.test'
        elif change == 'device':
            session.get(Device, 'bob-device').revoked_at = core[2][0]
        elif change == 'family':
            session.get(RefreshTokenFamily, 'bob-family').revoked_at = core[2][0]
        elif change == 'replacement':
            session.add(RefreshTokenFamily(id='bob-new-family', user_id='bob',
                device_id='bob-device', created_at=core[2][0]))
            session.flush()
            session.get(AdminSession, 'bob').family_id = 'bob-new-family'
        elif change == 'expired':
            session.get(AdminSession, 'bob').expires_at = core[2][0]
        else:
            actor['session_scope'] = 'app'
    with pytest.raises(AppError):
        service.detail(claims=actor, order_id=order['id'])
    with pytest.raises(AppError):
        service.claim(claims=actor, order_id=order['id'], idempotency_key='denied')
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == Decimal('10')


@pytest.mark.parametrize('change', ['role', 'family', 'disabled', 'unactivated', 'expiry'])
def test_order_authorizer_final_check_rereads_state_in_callers_transaction(scoped, change):
    core, service, claims = scoped
    with core[1].begin() as session:
        final = service.order_access.authorization(claims=claims['bob'])(session)
        if change == 'role':
            session.delete(session.get(UserRole, 'bob-finance'))
        elif change == 'family':
            session.get(RefreshTokenFamily, 'bob-family').revoked_at = core[2][0]
        elif change == 'disabled':
            session.get(User, 'bob').status = 'DISABLED'
        elif change == 'unactivated':
            session.delete(session.get(StaffActivation, 'bob'))
        else:
            core[2][0] += timedelta(hours=49)
        session.flush()
        with pytest.raises(AppError):
            final()
        session.rollback()


def test_passwordless_order_session_never_grants_owner_wallet_access(scoped):
    from app.modules.identity.wallet_grant import WalletAccessGrantService
    from app.modules.identity.operation_password_models import AdminOperationCredential
    from app.modules.identity.wallet_grant_models import WalletAccessGrant
    core, service, claims = scoped
    with core[1]() as session:
        assert session.scalar(select(AdminOperationCredential)) is None
        assert session.scalar(select(WalletAccessGrant)) is None
    service.order_access.require(claims=claims['bob'])
    wallet = WalletAccessGrantService(service.settings, core[1], lambda: core[2][0])
    for actor in ('bob', 'owner'):
        with pytest.raises(AppError):
            wallet.require(claims=claims[actor])
