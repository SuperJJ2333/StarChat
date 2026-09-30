import sys,json
from pathlib import Path
from hashlib import sha256
import pytest
sys.path.insert(0,str(Path(__file__).parent))
import public_verify as p
PATHS=('/api/v1/admin/support-orders/payouts/release-synthetic/takeover','/api/v1/admin/support-orders/payouts/release-synthetic/select-discovered','/api/v1/recharge/admin/requests/release-synthetic/takeover')
@pytest.mark.parametrize('status',['401','403','404','503','200'])
def test_candidate_anonymous_route_contract(monkeypatch,status):
    calls=[]
    def curl(url,proxy,status_only=False,post=False):
        calls.append((url,status_only,post))
        assert 'openapi' not in url
        if url.endswith('/health/ready'):return json.dumps({'ok':True,'database':'ready'}).encode()
        if post:return status.encode()
        if status_only:return b'401'
        return b'static'
    monkeypatch.setattr(p,'curl',curl)
    m={'static':[{'dest':'src/panel.js','after_sha256':sha256(b'static').hexdigest()}]}
    if status in ('401','403'):
        assert p.verify(m,None,'candidate')['strict_tls']
        assert tuple(url.removeprefix(p.API) for url,_,post in calls if post)==PATHS
    else:
        with pytest.raises(ValueError):p.verify(m,None,'candidate')

def test_post_curl_keeps_strict_tls_without_credentials(monkeypatch):
    commands=[]
    monkeypatch.setattr(p.subprocess,'check_output',lambda command,**kw:commands.append(command) or b'401')
    p.curl(p.API+PATHS[0],None,True,post=True)
    command=commands[0]
    assert '--insecure' not in command and '-k' not in command
    assert command[command.index('--proto')+1]=='=https'
    assert command[command.index('--request')+1]=='POST'
    assert command[command.index('--data')+1]=='{}'
    assert command[command.index('--header')+1]=='Content-Type: application/json'
    assert not any('Authorization' in value for value in command)
