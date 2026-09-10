from datetime import datetime, timedelta, timezone
from decimal import Decimal
import pytest
from sqlalchemy import create_engine
from app.core.database import Base, create_session_factory
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.redpacket.models import RedPacket
from app.modules.audit.models import AuditEvent

@pytest.fixture
def ledger_data():
    engine=create_engine('sqlite://');Base.metadata.create_all(engine, tables=[User.__table__, LedgerTransaction.__table__, LedgerEntry.__table__, RedPacket.__table__, AuditEvent.__table__])
    factory=create_session_factory(engine);now=datetime.now(timezone.utc)-timedelta(minutes=1)
    with factory.begin() as s:
        s.add(User(id='u',username='chat123',username_normalized='chat123',nickname='小明',
            email='test@example.test',email_normalized='test@example.test',password_hash='synthetic',
            status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
        s.add(RedPacket(id='packet',sender_id='u',total=Decimal('10'),share_count=2,mode='RANDOM',
            status='OPEN',room_id='room',recipient_id=None,idempotency_key='p',created_at=now,expires_at=now+timedelta(days=1)))
        for n,reason,scope,account in [(1,'RED_PACKET_CREATE','redpacket.create','PLATFORM_REDPACKET_ESCROW:packet'),(2,'OLD_CUSTOM_REASON','ledger.post','PLATFORM_CLEARING')]:
            tx=str(n);s.add(LedgerTransaction(id=tx,asset='CAIBI',scope=scope,idempotency_key=tx,actor_id='u',reason_code=reason,created_at=now))
            s.add_all([LedgerEntry(id=tx+'a',transaction_id=tx,account_id='u',asset='CAIBI',amount=Decimal('-10'),created_at=now),LedgerEntry(id=tx+'b',transaction_id=tx,account_id=account,asset='CAIBI',amount=Decimal('10'),created_at=now)])
    yield factory
    engine.dispose()

def test_classification_and_unknown_reason(ledger_data):
    from app.modules.admin.ledger_entries import ledger_page
    with ledger_data() as s:
        page=ledger_page(s,filters={'username':'chat123','nickname':'小明','email':'test@'},limit=50)
    assert len(page['items'])==2
    packet=next(i for i in page['items'] if i['transaction_id']=='1')
    assert packet['username']=='chat123' and packet['nickname']=='小明'
    assert packet['scene']=='UNKNOWN' and packet['mode']=='RANDOM'
    assert 'SCENE_UNVERIFIED' in packet['anomalies']
    assert packet['reason_text']=='发出红包' and packet['amount']=='-10.00'
    unknown=next(i for i in page['items'] if i['transaction_id']=='2')
    assert unknown['reason_text']=='原因待补充' and 'MISSING_REASON' in unknown['anomalies']

def test_pagination_filter_binding_and_internal_accounts(ledger_data):
    from app.modules.admin.ledger_entries import ledger_page
    with ledger_data() as s:
        first=ledger_page(s,filters={},limit=2)
        second=ledger_page(s,filters={},limit=2,cursor=first['next_cursor'])
        assert len({i['entry_id'] for i in first['items']+second['items']})==4
        assert any(i['account_kind']=='ESCROW' for i in first['items']+second['items'])
        with pytest.raises(ValueError):ledger_page(s,filters={'username':'another'},cursor=first['next_cursor'])

def test_combined_type_filter_and_invalid_range(ledger_data):
    from app.modules.admin.ledger_entries import ledger_page
    with ledger_data() as s:
        assert ledger_page(s,filters={'username':'chat123','scene':'UNKNOWN','mode':'RANDOM'})['total']==1
        assert ledger_page(s,filters={'scene':'GROUP'})['total']==0
        assert ledger_page(s,filters={'username':'chat123','mode':'EQUAL'})['total']==0
        with pytest.raises(ValueError):ledger_page(s,filters={'start_at':'2026-09-10T10:00:00','end_at':'2026-09-09T10:00:00'})


def test_other_reason_uses_only_matching_successful_audit_detail(ledger_data):
    from app.modules.admin.ledger_entries import ledger_page
    with ledger_data.begin() as s:
        s.add(AuditEvent(id='annotation', actor_id='u', subject_type='ledger_transaction', subject_id='2',
            action='ledger.reason.annotated', result='SUCCESS', reason_code='OLD_CUSTOM_REASON', trace_id='test',
            after_data={'reason_detail':'历史订单差额人工复核'}, created_at=datetime.now(timezone.utc)))
    with ledger_data() as s:
        page=ledger_page(s,filters={'username':'chat123'})
        item=next(i for i in page['items'] if i['transaction_id']=='2')
        assert item['reason_text']=='其他：历史订单差额人工复核'
        assert 'MISSING_REASON' not in item['anomalies']
