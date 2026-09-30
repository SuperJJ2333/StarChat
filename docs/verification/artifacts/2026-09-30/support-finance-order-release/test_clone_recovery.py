import copy,json
import pytest
import clone_recovery as q

def owned():
    name='admin-entry-restore-'+'a'*12;cid='b'*64;volume='c'*64;image='sha256:'+'d'*64
    return {'clone':name,'clone_id':cid},{'Name':'/'+name,'Id':cid,'Image':image,'State':{'Running':True},'HostConfig':{'NetworkMode':'none','Binds':None,'PortBindings':{}},'NetworkSettings':{'Ports':{}},'Mounts':[{'Type':'volume','Name':volume,'Destination':'/var/lib/postgresql/data','RW':True}]},image,volume

@pytest.mark.parametrize('change',['name','id','image','network','bind','port','volume','extra-mount'])
def test_cleanup_rejects_any_unowned_or_production_like_clone(change):
    restored,inspect,image,volume=owned()
    if change=='name':restored['clone']='starchat-postgres-1';inspect['Name']='/starchat-postgres-1'
    if change=='id':inspect['Id']='e'*64
    if change=='image':inspect['Image']='sha256:'+'e'*64
    if change=='network':inspect['HostConfig']['NetworkMode']='production'
    if change=='bind':inspect['HostConfig']['Binds']=['/production:/var/lib/postgresql/data']
    if change=='port':inspect['HostConfig']['PortBindings']={'5432/tcp':[{'HostPort':'5432'}]}
    if change=='volume':inspect['Mounts'][0]['Name']='production-volume'
    if change=='extra-mount':inspect['Mounts'].append({'Type':'bind','Source':'/production'})
    with pytest.raises(ValueError):q.validate_owned_clone(restored,inspect,image,volume)

def test_cleanup_accepts_exact_owned_clone_binding():
    restored,inspect,image,volume=owned()
    assert q.validate_owned_clone(restored,inspect,image,volume)==volume

def test_actual_worker_completion_marker_blocks_recovery(monkeypatch,tmp_path):
    monkeypatch.setattr(q.c,'PRIVATE',tmp_path)
    (tmp_path/'worker-probe-result.json').write_text('{}')
    with pytest.raises(ValueError,match='completed proof'):
        q.reject_production_or_completed_probe()

def test_probe_amendment_changes_only_probe_and_baseline_manifest_binding():
    old=json.dumps({'wallet_probe_sha256':'a'*64,'payload':{'x':'unchanged'},'other_proof':'fixed'}).encode()
    baseline=json.dumps({'manifest_sha256':q.sha_bytes(old),'backup_sha256':'b'*64,'containers':{'x':'unchanged'}}).encode()
    new,newbaseline=q.amended_documents(old,baseline,'c'*64,'a'*64)
    expected=json.loads(old);expected['wallet_probe_sha256']='c'*64
    assert json.loads(new)==expected
    expectedbaseline=json.loads(baseline);expectedbaseline['manifest_sha256']=q.sha_bytes(new)
    assert json.loads(newbaseline)==expectedbaseline
    with pytest.raises(ValueError):q.amended_documents(old,baseline,'c'*64,'d'*64)
    wrong=json.dumps({'manifest_sha256':'f'*64}).encode()
    with pytest.raises(ValueError):q.amended_documents(old,wrong,'c'*64,'a'*64)

def test_cleanup_only_ignores_obsolete_production_identity_but_preserves_bindings(monkeypatch,tmp_path):
    restored,current,image,volume=owned();current['Mounts'][0]['Source']='/anonymous/data'
    backup=b'private-backup';restored.update({'backup_sha256':q.sha_bytes(backup),'before':{'schema':q.s.BASE_SCHEMA},'candidate_images':{'api':'candidate'},'rollback_images':{'api':'fenced'}})
    manifest=json.dumps({'clone_image':image,'wallet_probe_sha256':'old-unchanged'}).encode()
    baseline=json.dumps({'manifest_sha256':q.sha_bytes(manifest),'backup_sha256':q.sha_bytes(backup)}).encode()
    monkeypatch.setattr(q.c,'PRIVATE',tmp_path);monkeypatch.setattr(q.s,'MANIFEST',tmp_path/'manifest.json');monkeypatch.setattr(q.c,'CLONE_IMAGE',image)
    (tmp_path/'manifest.json').write_bytes(manifest);(tmp_path/'baseline.json').write_bytes(baseline);(tmp_path/'business.dump').write_bytes(backup)
    for name,value in [('restore-running.json',restored),('images.json',restored['candidate_images']),('rollback-images.json',restored['rollback_images'])]:(tmp_path/name).write_text(json.dumps(value))
    (tmp_path/'last-command.stderr.private.log').write_bytes(b'failed fixture evidence')
    monkeypatch.setattr(q.s,'validate_manifest',lambda m:m)
    monkeypatch.setattr(q.c,'check_prepared',lambda *a,**kw:pytest.fail('obsolete production gate must not be invoked for cleanup-only'))
    monkeypatch.setattr(q.c,'restore',lambda *a:pytest.fail('cleanup-only must not restore'))
    monkeypatch.setattr(q.c,'docker_inspect',lambda *a:current)
    monkeypatch.setattr(q.c,'clone_database_value',lambda *a:q.s.TARGET_SCHEMA)
    removed=[]
    def run(*args,**kw):
        if args[:3]==('docker','volume','inspect'):return json.dumps([{'Name':volume,'Driver':'local','Labels':None,'Options':None,'Mountpoint':'/anonymous/data'}])
        if args[:2]==('docker','ps'):return restored['clone_id']
        if args[:3]==('docker','rm','-f'):removed.append(args[-1]);return ''
        return ''
    monkeypatch.setattr(q.c,'run',run)
    result=q.recover_clone(volume,cleanup_only=True)
    assert result['cleanup_only'] is True and removed==[restored['clone_id']]
    assert (tmp_path/'manifest.json').read_bytes()==manifest and (tmp_path/'baseline.json').read_bytes()==baseline
    attempt=tmp_path/result['attempt'];assert (attempt/'restore-running.json').exists()
    assert (attempt/'last-command.stderr.private.log').read_bytes()==b'failed fixture evidence'
