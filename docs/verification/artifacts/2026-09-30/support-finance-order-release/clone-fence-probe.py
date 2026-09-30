"""Synthetic real-ASGI fenced rollback rehearsal on an isolated restored0093 clone."""
import os
import json
from uuid import uuid4
from sqlalchemy import create_engine,text
from sqlalchemy.engine import make_url
from fastapi.testclient import TestClient

def main():
    url=make_url(os.environ['BUSINESS_DATABASE_URL'])
    if url.host!='127.0.0.1' or url.database!='clone' or url.username!='postgres':raise ValueError('dedicated local clone DSN required')
    engine=create_engine(url)
    schema='release_fence_'+uuid4().hex
    with engine.connect() as conn:
        assert conn.execute(text('select current_database()')).scalar_one()=='clone'
        assert conn.execute(text('select version_num from alembic_version')).scalar_one()=='0093_support_finance_order_recovery'
    try:
        with engine.begin() as conn:
            conn.execute(text('CREATE SCHEMA '+schema))
            for table in ('wallet_manual_payout_quotes','wallet_manual_payout_orders','wallet_support_payout_states','recharge_requests'):
                conn.execute(text(f'CREATE TABLE {schema}.{table} (LIKE public.{table} INCLUDING ALL)'))
            conn.execute(text('SET LOCAL search_path TO '+schema+',public'))
            conn.execute(text("INSERT INTO wallet_manual_payout_quotes (id,user_id,amount,snapshot,digest,created_at,expires_at) VALUES ('release-quote','synthetic',10,'{}',:digest,now(),now()+interval '2 hours')"),{'digest':'a'*64})
            for name,status in [('staged','REQUESTED'),('started','UNKNOWN'),('taken','UNKNOWN')]:
                conn.execute(text("INSERT INTO wallet_manual_payout_orders (id,quote_id,user_id,amount,digest,status,created_at,updated_at) VALUES (:id,'release-quote','synthetic',10,:digest,:status,now(),now())"),{'id':name,'digest':'a'*64,'status':status})
                conn.execute(text("INSERT INTO wallet_support_payout_states (order_id,expires_at,version,review_required,prepared_rate,prepared_receive,prepared_digest,prepared_version,evidence_actor_id,evidence_version,execution_started_at) VALUES (:id,now()+interval '2 hours',4,false,1,10,:digest,1,:actor,:version,:started)"),{'id':name,'digest':'b'*64,'actor':'owner' if name=='taken' else None,'version':1 if name=='taken' else 0,'started':None if name=='staged' else '2026-09-30T00:00:00Z'})
            conn.execute(text("INSERT INTO recharge_requests(id,user_id,amount_usdt,status,created_at,updated_at,claim_version,claimed_by) VALUES ('taken-recharge','synthetic',10,'SUBMITTED',now(),now(),4,'owner')"))
        os.environ['BUSINESS_DATABASE_URL']=url.update_query_dict({'options':'-csearch_path='+schema+',public'}).render_as_string(hide_password=False)
        from app.main import create_default_app
        with TestClient(create_default_app()) as client:
            ready=client.get('/api/v1/health/ready');assert ready.status_code==200
            for order in ('staged','started','taken'):
                for route in (f'/api/v1/admin/support-orders/payouts/{order}/adjust-rate',f'/api/v1/manual/payouts/{order}/cancel',f'/api/v1/wallet/manual/payouts/{order}/reconcile'):
                    result=client.post(route,json={});assert result.status_code==503 and result.json()['error']['code']=='SUPPORT_FINANCE_RELEASE_WRITE_FENCE'
            for route in ('/api/v1/recharge/requests','/api/v1/recharge/admin/requests/taken-recharge/execute-settlement','/api/v1/recharge/admin/requests/taken-recharge/takeover'):
                result=client.post(route,json={});assert result.status_code==503
            assert client.get('/api/v1/admin/support-orders/payouts').status_code in (401,403)
            assert client.post('/api/v1/auth/refresh',json={}).status_code!=503
        with engine.connect() as conn:
            assert conn.execute(text(f'SELECT count(*) FROM {schema}.wallet_manual_payout_orders')).scalar_one()==3
            assert conn.execute(text(f'SELECT count(*) FROM {schema}.recharge_requests')).scalar_one()==1
        print(json.dumps({'cases':['staged','started','evidence-takeover','recharge-takeover','health','auth-unfenced'],'passed':True,'synthetic_schema_only':True}))
    finally:
        with engine.begin() as conn:conn.execute(text('DROP SCHEMA IF EXISTS '+schema+' CASCADE'))
        engine.dispose()
if __name__=='__main__':main()
