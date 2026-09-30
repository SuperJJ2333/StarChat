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
