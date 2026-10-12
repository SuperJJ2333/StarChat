"""Local identity/closure audit. No SSH, HTTP, database or service calls."""
from pathlib import Path
import argparse
import ast
import hashlib
import json

HERE = Path(__file__).resolve().parent

def digest(data): return hashlib.sha256(data).hexdigest()

def main():
    manifest=json.loads((HERE/'preparation-input-identities.json').read_text(encoding='utf-8'))
    for name, expected in manifest['files'].items():
        path=HERE/name
        assert path.is_file() and not path.is_symlink(), name
        assert digest(path.read_bytes())==expected, 'Git-byte input mismatch: '+name
    count=0
    static=json.loads((HERE/'baseline/static-baseline.json').read_text(encoding='utf-8'))['files']
    for prefix in ('baseline','payload'):
        for name, identity in static.items():
            value=(HERE/prefix/'hk-snapshot'/name).read_bytes()
            assert digest(value)==identity['sha256'] and len(value)==identity['bytes']
            count+=1
    closure=json.loads((HERE/'postgres-closure.json').read_text(encoding='utf-8'))
    source=(HERE/'payload/settings_2215.py').read_text(encoding='utf-8')
    node=next(x for x in ast.parse(source).body if isinstance(x,ast.FunctionDef) and x.name=='transact')
    assert digest(ast.get_source_segment(source,node).encode())==closure['transaction_source_sha256']
    assert digest((HERE/'reused-postgres-2214.log').read_bytes())==closure['historical_log_git_sha256']
    hk=json.loads((HERE/'baseline/hk-live-snapshot.json').read_text(encoding='utf-8'))
    sg=json.loads((HERE/'baseline/sg-live-snapshot.json').read_text(encoding='utf-8'))
    assert hk['settings']['app_latest_build']=='2214' and hk['settings']['app_ios_latest_build']=='2213'
    assert hk['settings']['app_min_supported_build']==hk['settings']['app_ios_min_supported_build']=='3'
    assert len(hk['runtime'])==35 and not hk['target_exists']
    assert hk['schema']==['0095_wallet_source_alerts']
    assert sg['cloudfront']['DistributionConfig']['CacheBehaviors']['Quantity']==16 and sg['status']=='Deployed'
    for host in ('hk','sg'):
        metadata=json.loads((HERE/'baseline'/(host+'-projection-metadata.json')).read_text(encoding='utf-8'))
        assert digest((HERE/'baseline'/(host+'-projection-source.py')).read_bytes())==metadata['projection_source_sha256']
    parsed=0
    for name in manifest['files']:
        if name.endswith('.py'):
            ast.parse((HERE/name).read_text(encoding='utf-8')); parsed+=1
    print(json.dumps({'status':'PASS','identity_domain':'Git blob bytes; opaque captured bytes for 14 static inputs','files':len(manifest['files']),'static_original_bytes':count,'python_ast':parsed,'transaction_closure':'exact','pg_executed':False,'remote_actions':0},sort_keys=True))

if __name__=='__main__':main()
