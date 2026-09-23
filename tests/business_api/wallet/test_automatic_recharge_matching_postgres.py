"""Isolated PostgreSQL concurrent observer attribution, never production."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text, select, func
from sqlalchemy.engine import make_url
import test_deposit_receipts as original
from test_automatic_recharge_matching import setup_order
from app.modules.recharge.service import RechargeService
from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation


@pytest.fixture
def core(monkeypatch):
    raw=os.environ.get('RECHARGE_MATCH_TEST_DATABASE_URL')
    if not raw:pytest.skip('dedicated local recharge matching PostgreSQL not configured')
    url=make_url(raw)
    if url.host not in ('127.0.0.1','localhost') or url.database!='support_matching_review':
        raise RuntimeError('only dedicated local support_matching_review database is allowed')
    schema='recharge_match_'+uuid4().hex
    admin=create_engine(url,isolation_level='AUTOCOMMIT')
    with admin.connect() as connection:connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    schema_url=url.update_query_dict({'options':'-csearch_path='+schema})
    engine=create_engine(schema_url)
    generator=None
    try:
        from alembic import command
        from alembic.config import Config
        from app.core.database import Base
        service=Path(__file__).resolve().parents[3]/'services'/'business-api'
        config=Config(str(service/'alembic.ini'))
        config.set_main_option('script_location',str(service/'migrations'))
        config.set_main_option('path_separator','os')
        config.set_main_option('sqlalchemy.url',schema_url.render_as_string(hide_password=False).replace('%','%%'))
        monkeypatch.delenv('BUSINESS_DATABASE_URL',raising=False)
        command.upgrade(config,'head')
        with engine.begin() as connection:
            connection.execute(text('DELETE FROM wallet_controls'))
            connection.execute(text('DELETE FROM ledger_redeemability_reserve'))
        monkeypatch.setattr(Base.metadata,'create_all',lambda *a,**kw:None)
        monkeypatch.setattr(original,'create_engine',lambda *a,**kw:engine)
        generator=original.core.__wrapped__()
        yield next(generator)
    finally:
        if generator:generator.close()
        engine.dispose()
        with admin.connect() as connection:connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()


def test_two_workers_select_same_receipt_but_reserve_once(core,monkeypatch):
    first,_,clock=setup_order(core)
    second=RechargeService(core[1],ledger=first.ledger,wallet_receipts=core[0],
        official_config=core[0].official_config,now=lambda:clock[0])
    barrier=Barrier(2)
    read=core[0].observed_recharge_candidates
    def concurrent_read(**kwargs):
        result=read(**kwargs)
        barrier.wait(timeout=10)
        return result
    monkeypatch.setattr(core[0],'observed_recharge_candidates',concurrent_read)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda service:service.reconcile_observed_payments(),(first,second)))
    assert sum(r['matched'] for r in results)==1
    assert first.list_mine(user_id='alice')[0]['payment_verified']
    assert first.ledger.balance('alice')==0
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(RechargeReceiptReservation))==1
