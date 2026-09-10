"""Actual mounted HTTP flow with real test identity/grant and synthetic chain IO."""
import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
import httpx
import jwt
from coincurve import PrivateKey
from sqlalchemy import select, func

from app.core.config import Settings
from app.main import create_app
from app.integrations.tron.finality import SolidHead, TransactionEvidence, TransferEvidence
from app.integrations.tron.message_signature import address_from_public_key
from app.modules.identity.models import User, AccountStatus
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState, WalletAddressOwner
from app.modules.wallet.funding import OfficialFundingConfig
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.receipts import DepositReceiptService
from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
from app.modules.wallet.runtime import ManualWalletRuntime
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.safety import usdt_liability
from tests.business_api.identity.test_wallet_access_grant import grant_context  # noqa: F401


def test_mounted_repair_requires_grant_then_credits_exactly_once(grant_context, monkeypatch):
    _, factory, clock, claims, _ = grant_context
    now = datetime.now(timezone.utc)
    source, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as session:
        session.add(User(id='alice',username='alice',username_normalized='alice',email='alice@example.test',
            email_normalized='alice@example.test',password_hash='synthetic-only',status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
        session.add(WalletControl(id='global',withdrawals_paused=False))
        session.add(RedeemabilityReserve(id='global',eligible_usdt=Decimal('1000'),usdt_liability=0,
            version=1,pending_payouts=0,outgoing_restricted=False,observed_at=now))
        session.add(WalletAddressOwner(address=source,user_id='alice',created_at=now-timedelta(hours=1)))
        session.flush()
        session.add(WalletBinding(id='binding',user_id='alice',address=source,version=1,status='ACTIVE',
            created_at=now-timedelta(hours=1),activated_at=now-timedelta(hours=1),effective_from_block=101,
            barrier_height=100,barrier_block_id='a'*64,barrier_source_ids=['fixture'],barrier_observed_at=now))
        session.add(WalletBindingState(user_id='alice',version=1,active_binding_id='binding'))
        session.flush()
        session.add(DepositIntent(id='intent',user_id='alice',idempotency_key='intent',binding_id='binding',binding_version=1,
            binding_effective_from_block=101,source_address=source,official_address=official,official_config_version='test-v1',
            network='tron-mainnet',expected_amount=Decimal('10'),rules_snapshot={},status='EXPIRED',
            created_at=now-timedelta(minutes=5),expires_at=now-timedelta(minutes=2),closed_at=now-timedelta(minutes=1)))
    transfer_ms = int((now-timedelta(minutes=3)).timestamp()*1000)
    transfer = TransferEvidence('b'*64,0,102,'c'*64,transfer_ms,source,official,10000000)
    proof = TransactionEvidence('b'*64,102,'c'*64,transfer_ms,
        SolidHead(103,'d'*64,int(now.timestamp()*1000),now),(transfer,),now)
    adapter = SimpleNamespace(transaction_evidence=lambda txid:proof,close=lambda:None)
    receipts = DepositReceiptService(factory,finality_adapter=adapter,official_config=OfficialFundingConfig(official,'test-v1'),
        activation_baseline_time=now-timedelta(days=1),activation_baseline_height=100,clock=lambda:datetime.now(timezone.utc))
    receipt = receipts.ingest('b'*64,actor_id='fixture-worker')[0]
    runtime = ManualWalletRuntime(None,None,receipts,SimpleNamespace(),adapter,True)
    monkeypatch.setattr('app.main.create_manual_wallet_runtime',lambda *args:runtime)
    monkeypatch.setattr('app.api.admin.ClockHealth',lambda:SimpleNamespace(trusted=lambda:True))
    settings = Settings(_env_file=None,environment='test',database_url='sqlite://',
        jwt_secret='integration-test-wallet-secret-at-least-thirty-two',wallet_access_grant_enabled=True,
        wallet_admin_auth_mode='operation_password',wallet_manual_owner_admin_id='owner',
        wallet_access_policy_version='v1',wallet_manual_repairs_enabled=True)
    app = create_app(settings,session_factory=factory)
    settings.wallet_real_mode='manual_tron'
    token = jwt.encode(claims|{'iss':settings.jwt_issuer},settings.jwt_secret,algorithm='HS256')
    headers={'Authorization':'Bearer '+token,'Idempotency-Key':'http-command'}
    base='/api/v1/admin/wallet/manual/deposit-repairs'
    payload=dict(receipt_id=receipt['id'],intent_id='intent',reason_code='EXPIRED_INTENT_REVIEW',reason_detail='HTTP集成测试历史订单核对')

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url='http://test') as client:
            unauthorized=await client.get(base+'/candidates',params={'txid':'b'*64,'log_index':0})
            assert unauthorized.status_code==401
            blocked=await client.post(base+'/preview',headers=headers,json=payload)
            assert blocked.status_code==403 and blocked.json()['error']['code']=='WALLET_ACCESS_REQUIRED'
            verified=await client.post('/api/v1/wallet/manual/access/verify',headers=headers,
                json={'operation_password':'operation-password-123'})
            assert verified.status_code==200,verified.text
            candidates=await client.get(base+'/candidates',headers=headers,params={'txid':'b'*64,'log_index':0})
            assert candidates.status_code==200,candidates.text
            preview=await client.post(base+'/preview',headers=headers,json=payload)
            assert preview.status_code==200,preview.text
            value=preview.json()
            assert value['blockers']==[]
            command={k:value[k] for k in ('preview_id','digest','expected_version')}
            command.update(operation_id='http-operation',confirmed=True)
            result=await client.post(base,headers=headers,json=command)
            assert result.status_code==200,result.text
            assert result.json()['status']=='EXECUTED'
            replay=await client.post(base,headers=headers,json=command)
            assert replay.json()==result.json()
            conflict=await client.post(base,headers=headers,json=command|{'operation_id':'another'})
            assert conflict.status_code==409 and conflict.json()['error']['code']=='IDEMPOTENCY_CONFLICT'
            status=await client.get(base+'/http-operation',headers=headers)
            assert status.json()==result.json()
            assert status.headers['cache-control']=='no-store'
            revoked=await client.post('/api/v1/wallet/manual/access/revoke',headers=headers)
            assert revoked.status_code==200
            denied=await client.get(base+'/http-operation',headers=headers)
            assert denied.status_code==403 and denied.json()['error']['code']=='WALLET_ACCESS_REQUIRED'
    asyncio.run(run())
    assert receipts.wallet_ledger.balance('alice')==Decimal('10')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction))==1
        assert session.get(DepositIntent,'intent').status=='EXPIRED'
        assert usdt_liability(session)==Decimal('10')
