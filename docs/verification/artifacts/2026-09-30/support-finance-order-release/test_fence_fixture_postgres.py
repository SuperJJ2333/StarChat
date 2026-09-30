import importlib.util
from pathlib import Path
from uuid import uuid4
import os
from sqlalchemy import create_engine,text
from sqlalchemy.engine import make_url
from fastapi.testclient import TestClient

HERE=Path(__file__).parent
spec=importlib.util.spec_from_file_location('clone_fence_fixture',HERE/'clone-fence-probe.py')
probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)

def test_real_postgres_fixture_and_actual_asgi_fence(monkeypatch):
    url=make_url(os.environ['SUPPORT_ORDER_POSTGRES_URL'])
    assert url.host=='127.0.0.1' and url.database=='support_order_review_v2'
    engine=create_engine(url);schema='release_fixture_test_'+uuid4().hex
    try:
        with engine.begin() as conn:probe.seed_synthetic(conn,schema)
        with engine.connect() as conn:
            rows=conn.execute(text(f'SELECT id,quote_id,status,claimed_by,claimed_at FROM {schema}.wallet_manual_payout_orders ORDER BY id')).mappings().all()
            assert len(rows)==3 and len({row['quote_id'] for row in rows})==3
            assert all(row['claimed_by'] and row['claimed_at'] for row in rows if row['status']=='UNKNOWN')
            assert conn.execute(text(f'SELECT count(*) FROM {schema}.recharge_requests')).scalar_one()==1
        monkeypatch.setenv('BUSINESS_ENVIRONMENT','test')
        monkeypatch.setenv('BUSINESS_DATABASE_URL',url.update_query_dict({'options':'-csearch_path='+schema+',public'}).render_as_string(hide_password=False))
        from app.main import create_default_app
        from finance_write_fence import FinanceWriteFence
        app=create_default_app();app.add_middleware(FinanceWriteFence)
        with TestClient(app) as client:
            assert client.get('/api/v1/health/ready').status_code==200
            for path in ('/api/v1/wallet/manual/admin/payouts/started/void-unbroadcast','/api/v1/admin/support-orders/payouts/taken/adjust-rate','/api/v1/recharge/admin/requests/taken-recharge/execute-settlement'):
                result=client.post(path,json={});assert result.status_code==503
            assert client.get('/api/v1/admin/support-orders/payouts').status_code in (401,403)
    finally:
        with engine.begin() as conn:conn.execute(text('DROP SCHEMA IF EXISTS '+schema+' CASCADE'))
        engine.dispose()
