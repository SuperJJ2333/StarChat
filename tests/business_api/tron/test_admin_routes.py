from datetime import datetime, timezone
import importlib

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, update
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole, RefreshTokenFamily
from app.modules.identity.tokens import TokenService
from app.modules.wallet import binding_models, funding_models  # noqa: F401 - receipt FK targets
from tests.business_api.tron.test_admin_query import watch_db


@pytest.fixture
def chain_api(watch_db):
    module = importlib.import_module('app.api.wallet_chain')
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment='test', jwt_secret='test-' * 8)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    now = datetime.now(timezone.utc)
    headers = {}
    for identity, role in [('finance', RoleCode.FINANCE_SUPPORT), ('audit', RoleCode.SUPPORT_SUPERVISOR),
                           ('admin', RoleCode.SUPER_ADMIN), ('ordinary', RoleCode.USER)]:
        with factory.begin() as session:
            session.add(User(id=identity, username=identity, username_normalized=identity,
                             email=identity+'@example.invalid', email_normalized=identity+'@example.invalid',
                             password_hash='fixture', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
            session.add(UserRole(id=identity, user_id=identity, role_code=role, assigned_by='fixture', assigned_at=now))
        pair = tokens.issue_pair(user_id=identity, device_key=identity, display_name='fixture')
        headers[identity] = {'Authorization': 'Bearer '+pair.access_token}
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(module.create_wallet_chain_router(settings, factory, database_path=watch_db), prefix='/admin')
    yield TestClient(app), headers, factory, watch_db
    engine.dispose()


def test_authenticated_finance_or_auditor_only_and_query_audit(chain_api):
    client, headers, factory, _ = chain_api
    path = '/admin/wallet/chain/transactions'
    assert client.get(path).status_code == 401
    assert client.get(path, headers=headers['ordinary']).status_code == 403
    for actor in ['finance', 'audit', 'admin']:
        response = client.get(path, headers=headers[actor])
        assert response.status_code == 200, response.text
        assert response.json()['total'] == 3
        assert response.headers['cache-control'] == 'no-store'
    with factory() as session:
        events = list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'wallet.chain.viewed')))
        assert len(events) == 3
        assert {event.actor_id for event in events} == {'finance', 'audit', 'admin'}


def test_revoked_session_denied(chain_api):
    client, headers, factory, _ = chain_api
    with factory.begin() as session:
        session.execute(update(RefreshTokenFamily).values(revoked_at=datetime.now(timezone.utc)))
    assert client.get('/admin/wallet/chain/summary', headers=headers['finance']).status_code == 401


def test_chain_detail_includes_actual_platform_review_record(chain_api):
    from app.modules.wallet.receipt_models import DepositReceipt
    from app.integrations.tron.finality import NETWORK, POLICY, SOURCE_ID
    from app.integrations.tron.reader import USDT_CONTRACT
    client, headers, factory, _ = chain_api
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(DepositReceipt(id='review-receipt', network=NETWORK, contract=USDT_CONTRACT,
            txid='1'*64, log_index=0, source_address='synthetic-source', official_address='synthetic-official',
            official_config_version='test', amount_units='1', amount='0.000001', block_number=20,
            block_id='a'*64, block_time=now, evidence_policy=POLICY, evidence_source=SOURCE_ID,
            observed_at=now, facts_digest='b'*64, status='REVIEW', reason_code='BELOW_MINIMUM', pending_obligation=True))
    response = client.get('/admin/wallet/chain/transactions/'+'1'*64+'/0', headers=headers['finance'])
    assert response.status_code == 200
    result = response.json()
    assert result['ledger_status'] == 'REVIEW'
    assert result['user_attribution'] == 'UNVERIFIED'
    assert result['platform_record']['record_id'] == 'review-receipt'
    assert result['platform_record']['user_id'] is None


def test_detail_audit_subject_identifies_record_without_raw_transaction(chain_api):
    client, headers, factory, _ = chain_api
    for txid in ['1' * 64, '2' * 64]:
        response = client.get('/admin/wallet/chain/transactions/'+txid+'/0', headers=headers['finance'])
        assert response.status_code == 200
    with factory() as session:
        events = list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'wallet.chain.viewed')))
        subjects = {event.subject_id for event in events}
        assert len(subjects) == 2
        assert all(len(subject) == 64 for subject in subjects)
        assert subjects.isdisjoint({'1' * 64, '2' * 64})


def test_filter_validation_detail_and_unavailable(chain_api):
    client, headers, _, path = chain_api
    auth = headers['finance']
    base = '/admin/wallet/chain'
    assert client.get(base+'/summary', headers=auth).json()['watch_only'] is True
    assert client.get(base+'/transactions/'+ '1'*64+'/0', headers=auth).json()['amount'] == '0.000001'
    assert client.get(base+'/transactions/'+ '4'*64+'/0', headers=auth).status_code == 404
    for query in ['limit=101', 'direction=other', 'start_ms=10&end_ms=9', 'txid=no', 'offset=-1',
                  'snapshot=-1', 'snapshot=9223372036854775808']:
        assert client.get(base+'/transactions?'+query, headers=auth).status_code == 422
    path.write_bytes(b'corrupt')
    response = client.get(base+'/summary', headers=auth)
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'CHAIN_WATCH_UNAVAILABLE'
    assert str(path) not in response.text
