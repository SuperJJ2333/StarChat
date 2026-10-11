"""Parameterised installer transport and exact-origin release operations."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import release_2214 as release

CHUNK=16*1024*1024
ROLE='arn:aws:sts::218022113852:assumed-role/StarChatSgMaintenanceRole/i-035b46916e4cf43eb'

def verify_artifact(r,path):
    path=Path(path)
    if (not path.is_file() or path.is_symlink() or path.stat().st_size!=r['artifact_bytes']
            or release.digest(path)!=r['artifact_sha256']):raise ValueError('artifact SHA/size/regular-file mismatch')

@contextmanager
def stage_lock(stage):
    import fcntl
    stage=Path(stage)
    if not stage.is_dir() or stage.is_symlink():raise ValueError('private stage missing/linked')
    with (stage/'.delivery-2214.lock').open('a') as handle:
        fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB);yield

def split(r,source,directory):
    verify_artifact(r,source);directory=Path(directory)
    directory.mkdir(mode=0o700,exist_ok=False)
    parts=[]
    with Path(source).open('rb') as source_file:
        while block:=source_file.read(CHUNK):
            name=f'part-{len(parts):04d}'
            with (directory/name).open('xb') as target:
                target.write(block);target.flush();os.fsync(target.fileno())
            parts.append({'name':name,'bytes':len(block),'sha256':release.sha(block)})
    manifest={'sha256':r['artifact_sha256'],'bytes':r['artifact_bytes'],'parts':parts}
    (directory/'chunks.json').write_bytes(release.json_bytes(manifest))
    return manifest

def assemble(r,stage,*,lock=stage_lock):
    stage=Path(stage)
    with lock(stage):
        manifest=release.read_json(release.safe_file(stage,'chunks.json'))
        if manifest.get('sha256')!=r['artifact_sha256'] or manifest.get('bytes')!=r['artifact_bytes']:raise ValueError('chunk manifest identity drift')
        parts=manifest['parts'];count=(r['artifact_bytes']+CHUNK-1)//CHUNK
        if len(parts)!=count or [p['name'] for p in parts]!=[f'part-{i:04d}' for i in range(count)]:raise ValueError('chunk names/count drift')
        destination=stage/'final.apk'
        if destination.exists() or destination.is_symlink():
            verify_artifact(r,destination);return {'status':'already_exact','sha256':r['artifact_sha256']}
        fd,temporary=tempfile.mkstemp(prefix='.2214-assemble-',dir=stage)
        try:
            with os.fdopen(fd,'wb') as output:
                for part in parts:
                    source=release.safe_file(stage,part['name'])
                    if source.stat().st_size!=part['bytes'] or release.digest(source)!=part['sha256']:raise ValueError('chunk SHA/size mismatch')
                    with source.open('rb') as data:shutil.copyfileobj(data,output,1024*1024)
                output.flush();os.fsync(output.fileno())
            verify_artifact(r,temporary);os.chmod(temporary,0o600)
            os.link(temporary,destination)
        finally:Path(temporary).unlink(missing_ok=True)
        return {'status':'assembled_exact','sha256':r['artifact_sha256']}

def hk_state(r,root,stage,source=None):
    source=Path(source) if source is not None else Path(stage)/'final.apk'
    try:relative=source.absolute().relative_to(Path(stage).absolute())
    except ValueError:raise ValueError('source must be inside private stage')
    verify_artifact(r,release.safe_file(stage,relative))
    verify_artifact({'artifact_sha256':release.OLD_SHA,'artifact_bytes':release.OLD_BYTES},release.safe_file(root,'downloads/'+release.OLD_NAME))
    destination=release.safe_file(root,'downloads/'+release.NAME)
    if destination.exists() or destination.is_symlink():verify_artifact(r,destination)
    alias=Path(root)/'downloads/latest-arm64.apk'
    if not alias.is_symlink() or os.readlink(alias) not in (release.OLD_NAME,release.NAME):raise ValueError('HK alias drift')
    return {'installed':destination.exists(),'alias':os.readlink(alias)}

def hk(r,root,stage,mode,source=None):
    source=Path(source) if source is not None else Path(stage)/'final.apk'
    with release.host_lock(root):
        before=hk_state(r,root,stage,source)
        if mode=='hk-check':return before
        downloads=Path(root)/'downloads';destination=downloads/release.NAME
        if mode=='hk-install':
            if not before['installed']:
                fd,temporary=tempfile.mkstemp(prefix='.2214-apk-',dir=downloads)
                try:
                    with os.fdopen(fd,'wb') as target,source.open('rb') as input_file:
                        shutil.copyfileobj(input_file,target,1024*1024);target.flush();os.fsync(target.fileno())
                    verify_artifact(r,temporary);os.chmod(temporary,0o644);os.link(temporary,destination)
                finally:Path(temporary).unlink(missing_ok=True)
        else:
            if not before['installed']:raise ValueError('install immutable APK first')
            release.public_check(r,completed=False)
            if before['alias']==release.OLD_NAME:
                fd,name=tempfile.mkstemp(prefix='.2214-alias-',dir=downloads);os.close(fd);Path(name).unlink()
                try:
                    os.symlink(release.NAME,name)
                    if os.readlink(downloads/'latest-arm64.apk')!=release.OLD_NAME:raise ValueError('alias CAS drift')
                    os.replace(name,downloads/'latest-arm64.apk')
                finally:Path(name).unlink(missing_ok=True)
        return hk_state(r,root,stage,source)

def aws(*args):
    result=subprocess.run(['/usr/bin/aws',*args,'--output','json'],capture_output=True,text=True,check=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}

def cloud_state(r,stage):
    identity=aws('sts','get-caller-identity')
    if identity.get('Account')!='218022113852' or identity.get('Arn')!=ROLE:raise ValueError('AWS role/account drift')
    dist=aws('cloudfront','get-distribution','--id',release.DIST)['Distribution']
    if dist['DomainName']!='d12fjr06o6tga5.cloudfront.net':raise ValueError('CloudFront domain drift')
    current=aws('cloudfront','get-distribution-config','--id',release.DIST)
    policy=json.loads(aws('s3api','get-bucket-policy','--bucket',release.BUCKET)['Policy'])
    p=r['deployment'];cf_state=release.classify(p['cloudfront_before']['DistributionConfig'],p['cloudfront_after'],current['DistributionConfig'])
    if policy!=p['bucket_policy_before'] or policy!=p['bucket_policy_after']:raise ValueError('bucket policy drift; never overwrite')
    if cf_state=='before' and current['ETag']!=p['cloudfront_before']['ETag']:raise ValueError('CloudFront ETag drift')
    return {'cloudfront':cf_state,'policy':'unchanged','origin':'installer-hong-kong',
            'etag':current['ETag'],'status':dist['Status'],
            'artifact_sha256':r['artifact_sha256'],'artifact_bytes':r['artifact_bytes']}

def cloud_probe(r):
    import urllib.request
    release.public_check(r,completed=False)
    opener=urllib.request.build_opener(release.NoRedirect())
    request=urllib.request.Request(release.CDN,method='HEAD',headers={'Origin':'https://www.liuhetong888.com'})
    with opener.open(request,timeout=20) as response:
        if response.status!=200 or response.url!=release.CDN or int(response.headers.get('Content-Length','-1'))!=r['artifact_bytes']:
            raise ValueError('CDN HEAD drift')
        if response.headers.get('Access-Control-Allow-Origin')!='https://www.liuhetong888.com':raise ValueError('CDN HEAD CORS drift')
    return {'head':200,'cors':'https://www.liuhetong888.com'}

def cloud(r,stage,mode):
    stage=Path(stage)
    with stage_lock(stage):
        before=cloud_state(r,stage)
        if mode=='cdn-check':
            if before['cloudfront']=='complete' and before['status']=='Deployed':before['public']=cloud_probe(r)
            return before
        backup=stage/'cloud-2214-before.json'
        if backup.exists() and release.read_json(backup).get('plan')!=r['deployment']:
            raise ValueError('previous cloud backup belongs to another plan; inspect')
        if not backup.exists():
            with backup.open('xb') as output:output.write(release.json_bytes({'state':before,'plan':r['deployment']}))
            os.chmod(backup,0o600)
        if before['cloudfront']=='before':
            current=cloud_state(r,stage)
            if current['cloudfront']!='before' or current['etag']!=before['etag']:raise ValueError('distribution changed; inspect')
            target=stage/'cloudfront-2214-target.json';target.write_bytes(release.json_bytes(r['deployment']['cloudfront_after']))
            updated=aws('cloudfront','update-distribution','--id',release.DIST,'--if-match',before['etag'],'--distribution-config','file://'+str(target))
            if updated['Distribution']['DistributionConfig']!=r['deployment']['cloudfront_after']:raise ValueError('CloudFront update readback mismatch')
        after=cloud_state(r,stage)
        if after['cloudfront']!='complete' or after['policy']!='unchanged':raise ValueError('cloud readback mismatch')
        if after['status']=='Deployed':after['public']=cloud_probe(r)
        else:after['next']='Wait for Deployed, then cdn-check must pass public HEAD/CORS before HK alias switch'
        (stage/'cloud-2214-result.json').write_bytes(release.json_bytes(after))
        return after

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=('verify','split','assemble','hk-check','hk-install','hk-switch','cdn-check','cdn-install'))
    parser.add_argument('record',type=Path);parser.add_argument('--stage',type=Path,required=True)
    parser.add_argument('--source',type=Path);parser.add_argument('--root',type=Path,default=Path('/opt/starchat/frontend'))
    args=parser.parse_args();r=release.read_json(args.record);release.validate_release(r)
    if args.mode=='verify':
        verify_artifact(r,args.source or args.stage/'final.apk')
        result={'status':'ARTIFACT_EXACT','sha256':r['artifact_sha256'],'bytes':r['artifact_bytes']}
    elif args.mode=='split':
        if args.source is None:parser.error('split requires --source')
        result=split(r,args.source,args.stage)
    elif args.mode=='assemble':result=assemble(r,args.stage)
    elif args.mode.startswith('hk-'):result=hk(r,args.root,args.stage,args.mode,args.source)
    else:result=cloud(r,args.stage,args.mode)
    print(json.dumps(result,sort_keys=True))
if __name__=='__main__':main()
