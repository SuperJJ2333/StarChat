"""Explicit reviewed probe-only amendment and owned failed-clone recovery."""
import argparse,copy,json,os,re,shutil
from pathlib import Path
from uuid import uuid4
import server_release as s
from release_prep import sha_bytes,sha_file,require_hash
c=s.c
FIXED_PROBE_SHA='5c9ab84727b0a44acda65752a3afb081e8809104a07417039d85485f8cbf9b84'

def validate_owned_clone(restored,current,image,volume):
    name=restored['clone']
    if not re.fullmatch(r'admin-entry-restore-[0-9a-f]{12}',name):raise ValueError('unowned clone name')
    if not re.fullmatch(r'[0-9a-f]{64}',volume):raise ValueError('anonymous volume ID required')
    host=current.get('HostConfig',{});mounts=current.get('Mounts',[])
    if (current.get('Name')!='/'+name or current.get('Id')!=restored['clone_id'] or current.get('Image')!=image
            or host.get('NetworkMode')!='none' or host.get('Binds') or host.get('PortBindings')
            or any(current.get('NetworkSettings',{}).get('Ports',{}).values()) or current.get('State',{}).get('Running') is not True):
        raise ValueError('clone ID/image/isolation drift')
    if len(mounts)!=1 or mounts[0].get('Type')!='volume' or mounts[0].get('Name')!=volume or mounts[0].get('Destination')!='/var/lib/postgresql/data' or mounts[0].get('RW') is not True:
        raise ValueError('owned anonymous data volume drift')
    return volume

def amended_documents(old,baseline,new_probe,old_probe):
    require_hash(new_probe);require_hash(old_probe)
    m=json.loads(old);b=json.loads(baseline)
    if m['wallet_probe_sha256']!=old_probe or b['manifest_sha256']!=sha_bytes(old):raise ValueError('old manifest/probe binding drift')
    changed=copy.deepcopy(m);changed['wallet_probe_sha256']=new_probe
    fresh=(json.dumps(changed,indent=2,ensure_ascii=False)+'\n').encode()
    changed_baseline=copy.deepcopy(b);changed_baseline['manifest_sha256']=sha_bytes(fresh)
    return fresh,(json.dumps(changed_baseline,indent=2,ensure_ascii=False)+'\n').encode()

def attempt_directory(prefix):
    directory=c.PRIVATE/(prefix+'-'+uuid4().hex);directory.mkdir(mode=0o700)
    # Preserve failure stderr before any command can overwrite it.
    for path in c.PRIVATE.glob('*.private.log'):
        if path.is_symlink():raise ValueError('private log symlink')
        shutil.copyfile(path,directory/path.name);os.chmod(directory/path.name,0o600)
    return directory

def atomic_bytes(path,data):
    if path.is_symlink():raise ValueError('binding file symlink')
    temp=path.with_name(path.name+'.'+uuid4().hex+'.tmp')
    with temp.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    os.chmod(temp,0o600);os.replace(temp,path)

def reject_production_or_completed_probe():
    if any((c.PRIVATE/name).exists() for name in ('clone-compatibility.json','worker-probe.json','restore.json','bridge-attempt.json','worker-bridge-result.json','deployed.json')):
        raise ValueError('completed proof or production attempt blocks failed-clone recovery')

def amend_probe(old_manifest_sha,old_baseline_sha,old_probe,new_probe,old_probe_file):
    reject_production_or_completed_probe()
    if new_probe!=FIXED_PROBE_SHA or old_probe==new_probe:raise ValueError('only reviewed fixture probe revision may be amended')
    directory=attempt_directory('probe-amendment')
    old=s.MANIFEST.read_bytes();baseline_path=c.PRIVATE/'baseline.json';baseline=baseline_path.read_bytes()
    if sha_bytes(old)!=old_manifest_sha or sha_bytes(baseline)!=old_baseline_sha:raise ValueError('explicit old byte SHA differs')
    old_probe_file=Path(old_probe_file).resolve(strict=True)
    if not old_probe_file.is_relative_to(c.RELEASE_ROOT) or sha_file(old_probe_file)!=old_probe or sha_file(s.PACKAGE/'clone-fence-probe.py')!=new_probe:
        raise ValueError('reviewed old/new probe byte SHA differs')
    m=s.validate_manifest(json.loads(old));restored=c.read_private('restore-running.json')
    c.check_prepared(m,isolated_clone=restored);c.package_payload(m)
    fresh,newbaseline=amended_documents(old,baseline,new_probe,old_probe);s.validate_manifest(json.loads(fresh))
    for name,data in [('manifest.before.json',old),('baseline.before.json',baseline),('manifest.after.json',fresh),('baseline.after.json',newbaseline),('probe.before.py',old_probe_file.read_bytes()),('probe.after.py',(s.PACKAGE/'clone-fence-probe.py').read_bytes())]:
        (directory/name).write_bytes(data);os.chmod(directory/name,0o600)
    c.write_private(directory.name+'/intent.json',{'old_manifest_sha256':sha_bytes(old),'new_manifest_sha256':sha_bytes(fresh),'old_baseline_sha256':sha_bytes(baseline),'new_baseline_sha256':sha_bytes(newbaseline),'only_manifest_field':'wallet_probe_sha256','only_baseline_field':'manifest_sha256','payload_and_images_unchanged':True})
    atomic_bytes(s.MANIFEST,fresh);atomic_bytes(baseline_path,newbaseline)
    c.write_private(directory.name+'/completed.json',{'completed_utc':s.utc(),'manifest_sha256':sha_bytes(fresh),'baseline_sha256':sha_bytes(newbaseline)})
    return {'amended':True,'attempt':directory.name,'manifest_sha256':sha_bytes(fresh),'baseline_sha256':sha_bytes(newbaseline)}

def recover_clone(volume):
    reject_production_or_completed_probe();directory=attempt_directory('failed-clone-recovery')
    path=c.PRIVATE/'restore-running.json';raw=path.read_bytes();restored=json.loads(raw)
    shutil.copyfile(path,directory/'restore-running.before.json');os.chmod(directory/'restore-running.before.json',0o600)
    m=s.validate_manifest(json.loads(s.MANIFEST.read_text(encoding='utf-8')))
    if m['clone_image']!=c.CLONE_IMAGE or m['wallet_probe_sha256']!=FIXED_PROBE_SHA or sha_file(s.PACKAGE/'clone-fence-probe.py')!=FIXED_PROBE_SHA:
        raise ValueError('reviewed clone image and fixed fixture probe required')
    c.check_prepared(m,isolated_clone=restored)
    if (restored['backup_sha256']!=sha_file(c.PRIVATE/'business.dump') or restored['before']['schema']!=s.BASE_SCHEMA
            or restored['candidate_images']!=c.read_private('images.json') or restored['rollback_images']!=c.read_private('rollback-images.json')):
        raise ValueError('original clone backup/image identity drift')
    current=c.docker_inspect(restored['clone']);validate_owned_clone(restored,current,m['clone_image'],volume)
    inspected_volume=json.loads(c.run('docker','volume','inspect',volume))[0]
    if inspected_volume['Name']!=volume or inspected_volume.get('Driver')!='local' or inspected_volume.get('Labels') or inspected_volume.get('Options') or current['Mounts'][0].get('Source')!=inspected_volume.get('Mountpoint'):
        raise ValueError('anonymous local volume provenance drift')
    users=c.run('docker','ps','-a','-q','--no-trunc','--filter','volume='+volume).splitlines()
    if users!=[restored['clone_id']]:raise ValueError('clone volume is shared or substituted')
    head=c.clone_database_value(restored['clone'],'select version_num from alembic_version')
    if head not in (s.BASE_SCHEMA,s.TARGET_SCHEMA):raise ValueError('unexpected failed clone head')
    c.write_private(directory.name+'/intent.json',{'restore_record_sha256':sha_bytes(raw),'clone':restored['clone'],'clone_id':current['Id'],'clone_image':current['Image'],'volume':volume,'failed_head':head,'backup_sha256':restored['backup_sha256'],'fresh_restore_required':True})
    # Audited cleanup semantics, strengthened to remove the immutable ID rather
    # than a name that another process could replace between inspect and rm.
    c.run('docker','rm','-f','-v',current['Id'])
    if current['Id'] in c.run('docker','container','ls','-a','--no-trunc','--format','{{.ID}}').splitlines() or volume in c.run('docker','volume','ls','--format','{{.Name}}').splitlines():
        raise ValueError('owned clone/anonymous volume cleanup incomplete')
    c.write_private(directory.name+'/cleanup.json',{'clone_removed':True,'clone_volume_removed':True,'removed_container_id':current['Id'],'removed_volume':volume})
    path.rename(directory/'restore-running.json')
    fresh=c.restore(m)
    newrecord=c.read_private('restore-running.json')
    if newrecord['clone_id']==restored['clone_id'] or newrecord['backup_sha256']!=restored['backup_sha256'] or newrecord['before']['schema']!=s.BASE_SCHEMA:
        raise ValueError('fresh0093 restore identity failed')
    c.write_private(directory.name+'/completed.json',{'completed_utc':s.utc(),'fresh_clone_id':newrecord['clone_id'],'same_backup_sha256':restored['backup_sha256'],'schema':s.BASE_SCHEMA})
    return {'recovered':True,'attempt':directory.name,'fresh_restore':fresh,'rerun_probe_clone_required':True}

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='operation',required=True)
    amend=sub.add_parser('amend-probe')
    for flag in ('old-manifest-sha','old-baseline-sha','old-probe-sha','new-probe-sha','old-probe-file'):amend.add_argument('--'+flag,required=True)
    recover=sub.add_parser('recover-clone');recover.add_argument('--volume',required=True);args=p.parse_args()
    if s.PACKAGE!=c.RELEASE_ROOT:raise SystemExit('dedicated server release directory required')
    with s.exclusive_bridge_lock():
        result=amend_probe(args.old_manifest_sha,args.old_baseline_sha,args.old_probe_sha,args.new_probe_sha,args.old_probe_file) if args.operation=='amend-probe' else recover_clone(args.volume)
    print(json.dumps(result),flush=True)
if __name__=='__main__':main()
