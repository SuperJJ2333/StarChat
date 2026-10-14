from datetime import datetime, timezone
import pytest
import httpx
from app.integrations.tron import reader as mod
from app.integrations.tron.observer import Observer
from app.integrations.tron.funding_source import SQLiteFundingSource, FundingSourcePending
from test_reader import Chain, ACCOUNT
from test_observer import Reader, snapshot, rows

@pytest.mark.parametrize('message,code', [
    ('TRON solid head regressed','SOLID_HEAD_REGRESSED'),
    ('TRON solid head conflicted','SOLID_HEAD_CONFLICT'),
    ('TRON scan deadline exceeded','SCAN_DEADLINE'),
    ('secret-provider-address','SNAPSHOT_FAILED'),
])
def test_reason_persists_and_reaches_pending_without_advancing_checkpoint(tmp_path,message,code):
    now=[2000]
    source=Reader(snapshot(timestamp=1000,stable=True),snapshot(timestamp=2000,stable=True),mod.TronReadError(message))
    path=tmp_path/'watch.db'
    observer=Observer(path,source,ACCOUNT,now_ms=lambda:now[0],start_ms=0)
    observer.run_once(); now[0]=3000;observer.run_once();now[0]=4000
    assert observer.run_once()['error_code']==code
    assert rows(path,'runs')[-1]['error_code']==code
    assert rows(path,'observer_state')[0]['checkpoint_ms']==2000
    assert len(rows(path,'observations'))==2
    funding=SQLiteFundingSource(path,official_address=ACCOUNT,clock=lambda:datetime.fromtimestamp(4,timezone.utc))
    with pytest.raises(FundingSourcePending) as caught:funding.read_reserve_cut()
    expected=code if code!='SNAPSHOT_FAILED' else 'SOURCE_RUN_ERROR'
    assert caught.value.failed_conditions==(expected,)
    assert caught.value.since_ms==4000

@pytest.mark.parametrize('heads',[[110,112,111,112,112],[112,111,112,112]])
def test_regression_recovers_full_snapshot_and_discards_partial_data(monkeypatch,heads):
    monkeypatch.setattr(mod.time,'sleep',lambda _:None)
    chain=Chain();chain.heads=heads;chain.pages.append({'success':True,'data':[],'meta':{}})
    result=chain.reader().snapshot(ACCOUNT,1000,2000)
    assert result['stable_balance'] and result['solid_block']==112
    assert result['events']==[]
    assert sum(r.url.path.endswith('triggerconstantcontract') for r in chain.requests)==2


def test_regressed_floor_survives_all_attempts(monkeypatch):
    waits=[];monkeypatch.setattr(mod.time,'sleep',waits.append)
    chain=Chain();chain.heads=[112,111,111,111]
    with pytest.raises(mod.TronReadError,match='regressed'):chain.reader().snapshot(ACCOUNT,1000,2000)
    assert len(waits)==2
    assert len([r for r in chain.requests if r.url.path.endswith('getnowblock')])==4


def test_regression_cannot_reset_deadline(monkeypatch):
    clock=[100.];waits=[]
    monkeypatch.setattr(mod.time,'monotonic',lambda:clock[0])
    monkeypatch.setattr(mod.time,'sleep',lambda t:(waits.append(t),clock.__setitem__(0,clock[0]+t)))
    chain=Chain();chain.heads=[112,111,111,111]
    def respond(request):clock[0]+=0.6;return chain.respond(request)
    reader=mod.TronReader(client=httpx.Client(transport=httpx.MockTransport(respond)),max_scan_seconds=4)
    with pytest.raises(mod.TronReadError,match='regressed'):reader.snapshot(ACCOUNT,1000,2000)
    assert not waits

@pytest.mark.parametrize('position', ['within', 'between'])
@pytest.mark.parametrize('direction', ['height_up', 'time_up'])
def test_contradictory_head_order_is_not_retried(monkeypatch, position, direction):
    waits=[]
    monkeypatch.setattr(mod.time,'sleep',waits.append)
    heads = [(110,2000)]
    if position == 'between':
        heads.append((111,2001))
    baseline=heads[-1]
    heads.append((baseline[0]+1,baseline[1]-1) if direction=='height_up'
                 else (baseline[0]-1,baseline[1]+1))
    heads += [baseline,baseline]
    chain=Chain();chain.pages *= 3
    chain.heads=[head[0] for head in heads]
    reads=0
    def respond(request):
        nonlocal reads
        payload=chain.respond(request).json()
        if request.url.path.endswith('getnowblock'):
            payload['block_header']['raw_data']['timestamp']=heads[reads][1]
            reads+=1
        return httpx.Response(200,json=payload)
    reader=mod.TronReader(client=httpx.Client(transport=httpx.MockTransport(respond)))
    with pytest.raises(mod.TronReadError,match='conflicted'):
        reader.snapshot(ACCOUNT,1000,2000)
    assert not waits
