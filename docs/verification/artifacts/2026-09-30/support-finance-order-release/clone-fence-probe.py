"""Synthetic real-ASGI fenced rollback rehearsal on an isolated expanded0094 clone."""
import os
import json
from uuid import uuid4
from sqlalchemy import create_engine,text
from sqlalchemy.engine import make_url
from fastapi.testclient import TestClient

def seed_synthetic(conn,schema):
    conn.execute(text('CREATE SCHEMA '+schema))
    for table in ('users','wallet_manual_payout_quotes','wallet_manual_payout_orders','wallet_support_payout_states','recharge_requests'):
        conn.execute(text(f'CREATE TABLE {schema}.{table} (LIKE public.{table} INCLUDING ALL)'))
    conn.execute(text('SET LOCAL search_path TO '+schema+',public'))
    # LIKE copies checks and unique indexes, but not FKs. Keep every synthetic
    # reference inside the owned schema and exercise the real relationship too.
    for table,column,reference in [('wallet_manual_payout_orders','quote_id','wallet_manual_payout_quotes'),('wallet_support_payout_states','order_id','wallet_manual_payout_orders'),('recharge_requests','user_id','users')]:
        conn.execute(text(f'ALTER TABLE {schema}.{table} ADD FOREIGN KEY ({column}) REFERENCES {schema}.{reference}(id)'))
    for user in ('synthetic','payer','owner'):
        conn.execute(text("INSERT INTO users(id,username,username_normalized,nickname,password_hash,status,profile_updated_at,created_at,updated_at) VALUES (:id,:username,:normalized,:nickname,'UNUSABLE_SYNTHETIC','ACTIVE',now(),now(),now())"),{'id':user,'username':user,'normalized':user,'nickname':user})
    for name,status in [('staged','REQUESTED'),('started','UNKNOWN'),('taken','UNKNOWN')]:
        conn.execute(text("INSERT INTO wallet_manual_payout_quotes (id,user_id,amount,snapshot,digest,created_at,expires_at) VALUES (:quote,'synthetic',10,:snapshot,:digest,now(),now()+interval '2 hours')"),{'quote':'quote-'+name,'digest':'a'*64,'snapshot':json.dumps({'funding_asset':'USDT','receive':'10.000000','owner_admin_id':'owner','target_address':'SYNTHETIC_TARGET','official_address':'SYNTHETIC_OFFICIAL'})})
        conn.execute(text("INSERT INTO wallet_manual_payout_orders (id,quote_id,user_id,amount,digest,status,claimed_by,claimed_at,created_at,updated_at) VALUES (:id,:quote,'synthetic',10,:digest,:status,:payer,CASE WHEN :claimed THEN now() ELSE NULL END,now(),now())"),{'id':name,'quote':'quote-'+name,'digest':'a'*64,'status':status,'payer':None if name=='staged' else 'payer','claimed':name!='staged'})
        conn.execute(text("INSERT INTO wallet_support_payout_states (order_id,expires_at,version,review_required,claimed_by,claim_token,claim_expires_at,prepared_rate,prepared_receive,prepared_digest,prepared_version,evidence_actor_id,evidence_token_hash,evidence_version,execution_started_at) VALUES (:id,now()+interval '2 hours',4,false,'payer',:claim,now()+interval '5 minutes',1,10,:digest,1,:actor,:evidence,:version,CASE WHEN :started THEN now() ELSE NULL END)"),{'id':name,'claim':'c'*64,'digest':'b'*64,'actor':'owner' if name=='taken' else None,'evidence':'d'*64 if name=='taken' else None,'version':1 if name=='taken' else 0,'started':name!='staged'})
    conn.execute(text("INSERT INTO recharge_requests(id,user_id,amount_usdt,status,created_at,updated_at,claim_version,claimed_by,claim_token_hash,claim_expires_at,expires_at,processing_stage,official_payment) VALUES ('taken-recharge','synthetic',10,'SUBMITTED',now(),now(),4,'owner',:token,now()+interval '5 minutes',now()+interval '2 hours','CLAIMED',:payment)"),{'token':'e'*64,'payment':json.dumps({'address':'SYNTHETIC_OFFICIAL','asset':'USDT'})})

def main():
    url=make_url(os.environ['BUSINESS_DATABASE_URL'])
    if url.host!='127.0.0.1' or url.database!='clone' or url.username!='postgres':raise ValueError('dedicated local clone DSN required')
    engine=create_engine(url)
    schema='release_fence_'+uuid4().hex
    with engine.connect() as conn:
        assert conn.execute(text('select current_database()')).scalar_one()=='clone'
        assert conn.execute(text('select version_num from alembic_version')).scalar_one()=='0094_support_finance_order_recovery'
    try:
        with engine.begin() as conn:
            seed_synthetic(conn,schema)
        os.environ['BUSINESS_DATABASE_URL']=url.update_query_dict({'options':'-csearch_path='+schema+',public'}).render_as_string(hide_password=False)
        from app.main import create_default_app
        with TestClient(create_default_app()) as client:
            ready=client.get('/api/v1/health/ready');assert ready.status_code==200
            for order in ('staged','started','taken'):
                for route in (f'/api/v1/admin/support-orders/payouts/{order}/adjust-rate',f'/api/v1/manual/payouts/{order}/cancel',f'/api/v1/wallet/manual/payouts/{order}/reconcile',f'/api/v1/wallet/manual/admin/payouts/{order}/void-unbroadcast'):
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
