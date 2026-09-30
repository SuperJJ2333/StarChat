import copy,sys,json
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).parent))
import server_release as s

@pytest.mark.parametrize('drift',[None,'duplicate','mode','mount'])
def test_runtime_mount_order_only(monkeypatch,drift):
    original={'Config':{'Env':['A=1'],'Cmd':['run']},'HostConfig':{'Binds':['/a:/a:ro','/b:/b:rw'],'Mounts':[{'Target':'/a','ReadOnly':True},{'Target':'/b','ReadOnly':False}]},'Mounts':[{'Source':'/a','Destination':'/a','RW':False},{'Source':'/b','Destination':'/b','RW':True}]}
    now=copy.deepcopy(original)
    for key in ('Binds','Mounts'):now['HostConfig'][key].reverse()
    now['Mounts'].reverse()
    if drift=='duplicate':now['HostConfig']['Binds'].append(now['HostConfig']['Binds'][0])
    if drift=='mode':now['HostConfig']['Binds'][0]='/b:/b:ro'
    if drift=='mount':now['Mounts'][0]['RW']=False
    monkeypatch.setattr(s.c,'read_private',lambda name:original)
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:now)
    if drift:
        with pytest.raises(ValueError):s.c._same_runtime_configuration('api')
    else:s.c._same_runtime_configuration('api')

@pytest.mark.parametrize('fault',[None,'phase','marker','id','sha','fence','migration'])
def test_resume_existing_fence_only(monkeypatch,tmp_path,fault):
    image={'api':'fenced','worker':'baseworker'};candidate={'api':'candidate','worker':'safeworker'}
    snap=tmp_path/'guard.json';snap.write_text('{}')
    api={'Id':'a'*64,'Image':'fenced','RestartCount':0,'Config':{'Labels':{'com.docker.compose.project':'starchat','com.docker.compose.service':'business-api','com.docker.compose.project.config_files':str(snap)}}}
    worker={'Id':'workerid','Image':'baseworker','Config':{'Labels':{'com.docker.compose.project.config_files':'worker.json'}}}
    records={'bridge-failure.json':{'phase':'guarded-fence-health','guard_snapshot':str(snap),'images':image},'bridge-attempt.json':{'images':image},'images.json':candidate,'rollback-images.json':{'api':'fenced','worker':'safeworker'},'worker-container-inspect.json':worker,'merged-baseline-compose.json':{'services':{'business-api':{'image':'baseapi'},'business-worker':{'image':'baseworker'}}}}
    if fault=='phase':records['bridge-failure.json']['phase']='single-bounded-expand'
    if fault=='marker':(tmp_path/'bridge-migration-attempt.json').write_text('{}')
    calls=[];writes=[];schemas=iter([s.BASE_SCHEMA,s.BASE_SCHEMA,s.TARGET_SCHEMA])
    monkeypatch.setattr(s.c,'PRIVATE',tmp_path)
    monkeypatch.setattr(s.c,'read_private',lambda name:records[name])
    monkeypatch.setattr(s.c,'write_private',lambda name,value:writes.append(name))
    monkeypatch.setattr(s,'validate_restore',lambda m:{})
    monkeypatch.setattr(s,'before_switch',lambda *a:{})
    monkeypatch.setattr(s,'sha_file',lambda p:'c'*64)
    monkeypatch.setattr(s.c,'_selected_health',lambda *a,**kw:{'api':api,'worker':worker})
    monkeypatch.setattr(s.c,'docker_inspect',lambda name:api)
    monkeypatch.setattr(s.c,'database_value',lambda *a:next(schemas))
    monkeypatch.setattr(s.c,'_restart_counts',lambda h:{'api':0,'worker':0})
    monkeypatch.setattr(s.c,'_guard',lambda *a,**kw:pytest.fail('resume must not deploy'))
    def fence(*a):
        if fault=='fence':raise ValueError('fence')
        return {'passed':True,'actual_http':True}
    monkeypatch.setattr(s,'bridge_runtime_fence',fence)
    def run(*a,**kw):
        calls.append(a)
        if a[:2]==('docker','compose'):return json.dumps({'services':{'business-api':{'image':'fenced'},'business-worker':{'image':'baseworker'}}})
        if fault=='migration':raise TimeoutError('bounded migration')
        return ''
    monkeypatch.setattr(s.c,'run',run)
    m={'roles':{'api':{'base_image':'baseapi'},'worker':{'base_image':'baseworker'}}}
    args=(m,'b'*64 if fault=='id' else 'a'*64,'wrong' if fault=='sha' else 'c'*64)
    if fault:
        with pytest.raises((ValueError,TimeoutError)):s._resume_bridge_locked(*args)
        assert 'bridge-result.json' not in writes
    else:
        assert s._resume_bridge_locked(*args)['bridge_fenced']
        assert 'bridge-result.json' in writes
    migration=[a for a in calls if a[:2]==('docker','exec')]
    assert len(migration)==(1 if fault in (None,'migration') else 0)
    if migration:assert migration[0][4]=='a'*64 and '150s' in migration[0]
    if fault in ('fence','migration'):assert any(name.endswith('/failure.json') for name in writes)
