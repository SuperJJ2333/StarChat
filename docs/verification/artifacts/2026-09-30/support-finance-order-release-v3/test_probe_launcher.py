import json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
import server_release as s

def test_api_fence_probe_uses_cwd_preserving_runpy(monkeypatch,tmp_path):
    calls=[];records={
        'restore-running.json':{'clone':'isolated','clone_id':'immutable','before':{},'candidate_images':{'api':'candidate'},'rollback_images':{'api':'fenced'}},
        'images.json':{'api':'candidate'},'rollback-images.json':{'api':'fenced'}}
    monkeypatch.setattr(s.c,'PRIVATE',tmp_path)
    monkeypatch.setattr(s.c,'check_prepared',lambda *args,**kwargs:None)
    monkeypatch.setattr(s.c,'read_private',lambda name:records[name])
    monkeypatch.setattr(s.c,'write_private',lambda *args:None)
    monkeypatch.setattr(s.c,'_clone_runner',lambda *args:['docker','run','--workdir','/opt/business-api'])
    monkeypatch.setattr(s.c,'docker_inspect',lambda *args:{'Id':'immutable','HostConfig':{'NetworkMode':'none'}})
    snapshots=iter([{'schema':s.BASE_SCHEMA},{'schema':s.TARGET_SCHEMA}])
    monkeypatch.setattr(s.c,'clone_snapshot',lambda *args,**kwargs:next(snapshots))
    monkeypatch.setattr(s.c,'clone_startup_command',lambda *args:['docker','startup'])
    monkeypatch.setattr(s,'fingerprint',lambda *args:{'unchanged':True})
    monkeypatch.setattr(s,'sha_file',lambda *args:'probe-sha')
    def run(*args,**kwargs):
        calls.append(args);return json.dumps({'ok':True})
    monkeypatch.setattr(s.c,'run',run)
    s.probe_clone({'wallet_probe_sha256':'probe-sha'})
    command=next(args for args in calls if '/tmp/probe.py' in ' '.join(args))
    assert command[-2]=='-c'
    assert command[-1]=="import runpy;runpy.run_path('/tmp/probe.py',run_name='__main__')"
    assert not any('PYTHONPATH' in arg for arg in command)
