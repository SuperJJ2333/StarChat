import json,sys,copy
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).parent))
import server_release as s
IMAGES={'api':'sha256:'+'a'*64,'worker':'sha256:'+'b'*64}


def config():
    return {'name':'starchat','networks':{'default':{'name':'starchat_default'}},'services':{
        'business-api':{'image':IMAGES['api'],'environment':{'SAFE':'yes'},'command':['uvicorn'], 'privileged':False},
        'business-worker':{'image':IMAGES['worker'],'environment':{'SAFE':'yes'},'command':['worker'], 'privileged':False}}}

def sources():
    a=config();a['services']['business-worker']['image']='worker-stale'
    return {'api':{'original_path':'api.json','rendered':a},'worker':{'original_path':'worker.json','rendered':config()}}

def runtime(role,path='api.json'):
    return {'Image':IMAGES[role],'Config':{'Env':['SAFE=yes'],'Labels':{'com.docker.compose.project':'starchat','com.docker.compose.service':s.ROLE_SERVICE[role],'com.docker.compose.project.config_files':path}}}

def test_own_role_source_accepts_stale_peer(monkeypatch):
    monkeypatch.setattr(s.c,'sha_file',lambda p:'sha')
    monkeypatch.setattr(s.c,'run',lambda *a:json.dumps(sources()['api']['rendered']))
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:runtime('worker'))
    assert s.c.compose_input(runtime('api'),'api','sha')[1]==sources()['api']['rendered']

@pytest.mark.parametrize('fault',['image','environment','label','sha'])
def test_own_role_source_rejects_actual_drift(monkeypatch,fault):
    data=sources()['api']['rendered'];actual=runtime('api')
    if fault=='image':actual['Image']='other'
    if fault=='environment':actual['Config']['Env']=['SAFE=no']
    if fault=='label':actual['Config']['Labels']['com.docker.compose.service']='business-worker'
    monkeypatch.setattr(s.c,'sha_file',lambda p:'wrong' if fault=='sha' else 'sha')
    monkeypatch.setattr(s.c,'run',lambda *a:json.dumps(data))
    with pytest.raises(ValueError):s.c.compose_input(actual,'api','sha')

def test_source_consistency_ignores_peer_but_rejects_top_level_drift():
    data=sources();s.c.assert_source_compose_consistency(data)
    data['worker']['rendered']['networks']['default']['name']='other'
    with pytest.raises(ValueError):s.c.assert_source_compose_consistency(data)

@pytest.mark.parametrize('tamper',[False,True])
def test_baseline_merge_uses_private_owned_slices_and_exact_comparison(monkeypatch,tamper):
    data=sources();seen=[]
    def run(*args):
        paths=[Path(args[i+1]) for i,v in enumerate(args) if v=='-f']
        seen.extend(paths)
        parts=[json.loads(p.read_text()) for p in paths]
        assert [set(p['services']) for p in parts]==[{'business-api'},{'business-worker'}]
        assert all(p.stat().st_mode & 0o077==0 for p in paths) if sys.platform!='win32' else True
        merged=copy.deepcopy(parts[0]);merged['services'].update(parts[1]['services'])
        if tamper:merged['services']['business-api']['privileged']=True
        return json.dumps(merged)
    monkeypatch.setattr(s.c,'run',run)
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:runtime('api' if name==s.ROLE_CONTAINER['api'] else 'worker'))
    manifest={'roles':{r:{'base_image':IMAGES[r]} for r in ('api','worker')}}
    if tamper:
        with pytest.raises(ValueError):s.c.render_merged_baseline(manifest,data)
    else:assert s.c.render_merged_baseline(manifest,data)==config()
    assert all(not p.exists() for p in seen)


def test_baseline_preserves_literal_dollars_in_normalized_values(monkeypatch):
    data=sources()
    for record in data.values():
        record['rendered']['networks']['default']['labels']={'note':'literal$top'}
        for service in record['rendered']['services'].values():
            service['environment']['SAFE']='literal$env'
            service['command']=['echo','literal$command']
    def render(*args):
        parts=[json.loads(Path(args[i+1]).read_text()) for i,v in enumerate(args) if v=='-f']
        for part in parts:
            assert part['networks']['default']['labels']['note']=='literal$$top'
            owned=next(iter(part['services'].values()))
            assert owned['environment']['SAFE']=='literal$$env'
            assert owned['command'][1]=='literal$$command'
        def normalize(v):
            if isinstance(v,str):return v.replace('$$','$')
            if isinstance(v,list):return [normalize(x) for x in v]
            if isinstance(v,dict):return {k:normalize(x) for k,x in v.items()}
            return v
        merged=normalize(parts[0]);merged['services'].update(normalize(parts[1])['services'])
        return json.dumps(merged)
    def live(name):
        role='api' if name==s.ROLE_CONTAINER['api'] else 'worker'
        value=runtime(role);value['Config']['Env']=['SAFE=literal$env'];return value
    monkeypatch.setattr(s.c,'run',render);monkeypatch.setattr(s.c,'docker_inspect',live)
    manifest={'roles':{r:{'base_image':IMAGES[r]} for r in ('api','worker')}}
    assert s.c.render_merged_baseline(manifest,data)['services']['business-api']['environment']['SAFE']=='literal$env'
