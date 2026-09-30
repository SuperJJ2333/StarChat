from pathlib import Path
import importlib.util
import asyncio
import pytest
S=importlib.util.spec_from_file_location('fence',Path(__file__).with_name('finance_write_fence.py'));f=importlib.util.module_from_spec(S);S.loader.exec_module(f)
async def call(path,method):
    events=[]
    async def app(scope,receive,send):await send({'type':'http.response.start','status':200})
    async def receive():return {'type':'http.request','body':b''}
    async def send(event):events.append(event)
    await f.FinanceWriteFence(app)({'type':'http','method':method,'path':path},receive,send)
    return events
@pytest.mark.parametrize('prefix',f.PREFIXES)
@pytest.mark.parametrize('method',['POST','PUT','PATCH','DELETE'])
def test_all_affected_mutations_block_before_auth_or_body(prefix,method):
    result=asyncio.run(call(prefix+'/synthetic-order/cancel',method))
    assert result[0]['status']==503
    assert b'SUPPORT_FINANCE_RELEASE_WRITE_FENCE' in result[1]['body']
@pytest.mark.parametrize('path',['/api/v1/auth/refresh','/api/v1/health/ready','/api/v1/identity/me','/api/v1/manual/transfers'])
def test_other_api_routes_unchanged(path):assert asyncio.run(call(path,'POST'))[0]['status']==200
@pytest.mark.parametrize('method',['GET','HEAD','OPTIONS'])
def test_reads_and_preflight_unchanged(method):assert asyncio.run(call('/api/v1/recharge/admin/requests',method))[0]['status']==200
