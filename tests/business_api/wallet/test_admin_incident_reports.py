from importlib.util import find_spec

def test_incident_read_projection_exists():
    assert find_spec('app.modules.wallet.incident_reports') is not None

from datetime import timedelta
import pytest
from app.core.errors import AppError
from app.modules.wallet.incident_reports import WalletIncidentReports
from test_wallet_incidents import factory, service, SIGNAL, NOW  # noqa: F401


def populate(factory):
    return [service(factory,NOW+timedelta(minutes=i)).observe([dict(SIGNAL,fingerprint='withdrawal:item'+str(i),subject_id='item'+str(i),severity='P1' if i==1 else 'P0')],complete=False)[0] for i in range(3)]


def test_filters_sort_keyset_and_total(factory):
    rows=populate(factory)
    reports=WalletIncidentReports(factory,cursor_secret='fixture',clock=lambda:NOW)
    first=reports.list(limit=1,severity=['P0'],sort='opened_desc')
    assert first['total']==2 and first['items'][0]['id']==rows[2]['id']
    second=reports.list(limit=1,severity=['P0'],sort='opened_desc',cursor=first['next_cursor'])
    assert second['items'][0]['id']==rows[0]['id'] and second['next_cursor'] is None
    assert reports.list(sort='opened_asc')['items'][0]['id']==rows[0]['id']
    assert reports.list(code=['MISSING_CODE'])['total']==0


def test_cursor_cannot_cross_filters_or_mutated_membership(factory):
    rows=populate(factory)
    reports=WalletIncidentReports(factory,cursor_secret='fixture',clock=lambda:NOW)
    first=reports.list(limit=1)
    with pytest.raises(AppError) as exc: reports.list(limit=1,status=['OPEN'],cursor=first['next_cursor'])
    assert exc.value.code=='WALLET_INCIDENT_CURSOR_FILTER_CONFLICT'
    service(factory).ack(rows[0]['id'],'owner','INVESTIGATE','ack',rows[0]['version'])
    with pytest.raises(AppError) as exc: reports.list(limit=1,cursor=first['next_cursor'])
    assert exc.value.code=='WALLET_INCIDENT_SNAPSHOT_CHANGED'


def test_detail_uses_only_persisted_exact_subject_audit(factory):
    rows=populate(factory)
    svc=service(factory,NOW+timedelta(minutes=3))
    svc.ack(rows[0]['id'],'owner','INVESTIGATE','ack',rows[0]['version'])
    reports=WalletIncidentReports(factory,cursor_secret='fixture')
    detail=reports.detail(rows[0]['id'])
    assert [event['action'] for event in detail['timeline']]==['wallet.incident.opened','wallet.incident.ack']
    assert all(event['reason_code'] in {'WITHDRAWAL_UNKNOWN','INVESTIGATE'} for event in detail['timeline'])
    assert detail['related_records']==[]  # No real record exists for the arbitrary subject string.
    assert all('after_data' not in event for event in detail['timeline'])


def test_cursor_tamper_rejected(factory):
    populate(factory)
    reports=WalletIncidentReports(factory,cursor_secret='fixture')
    cursor=reports.list(limit=1)['next_cursor']
    with pytest.raises(AppError): reports.list(cursor=cursor+'x')


def test_related_records_require_existing_explicit_subject(factory):
    from app.modules.wallet.models import Withdrawal
    rows=populate(factory)
    with factory.begin() as session:
        session.add(Withdrawal(id='item0',user_id='alice',client_order_id='fixture',address='fixture-only',
            amount='10.000000',status='UNKNOWN',created_at=NOW,updated_at=NOW))
    detail=WalletIncidentReports(factory,cursor_secret='fixture').detail(rows[0]['id'])
    assert detail['related_records']==[dict(kind='WITHDRAWAL',id='item0',relation='EXPLICIT_INCIDENT_LINK')]
    other=WalletIncidentReports(factory,cursor_secret='fixture').detail(rows[1]['id'])
    assert other['related_records']==[]


def test_updated_sort_and_heartbeat_cannot_silently_shift_page(factory):
    rows=populate(factory)
    reports=WalletIncidentReports(factory,cursor_secret='fixture')
    page=reports.list(sort='updated_desc',limit=1)
    assert page['items'][0]['id']==rows[2]['id']
    service(factory,NOW+timedelta(minutes=5)).observe([dict(SIGNAL,fingerprint='withdrawal:item0',subject_id='item0')],complete=False)
    with pytest.raises(AppError) as exc: reports.list(sort='updated_desc',limit=1,cursor=page['next_cursor'])
    assert exc.value.code=='WALLET_INCIDENT_SNAPSHOT_CHANGED'


def test_timeline_never_transmits_arbitrary_audit_metadata(factory):
    from app.modules.audit.writer import AuditWriter
    rows=populate(factory)
    AuditWriter(factory,now_factory=lambda:NOW+timedelta(minutes=10)).record(actor_id='owner',
        subject_type='wallet_incident',subject_id=rows[0]['id'],action='wallet.incident.review',result='SUCCESS',
        reason_code='REVIEW',trace_id='fixture',after={'status':{'private':'DO_NOT_EXPOSE'},'generation':['private'],'version':True,'condition_active':'yes'})
    detail=WalletIncidentReports(factory,cursor_secret='fixture').detail(rows[0]['id'])
    event=detail['timeline'][-1]
    assert all(event[key] is None for key in ('status','generation','version','condition_active'))
    assert 'DO_NOT_EXPOSE' not in str(detail)
