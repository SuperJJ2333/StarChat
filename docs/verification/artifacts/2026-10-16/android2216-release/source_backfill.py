"""Prepare exact local reconciliation; apply only after confirmed publish/audit."""
from pathlib import Path
import argparse, hashlib, json
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[4]
PACKAGE=HERE/'publication-final-2216-20261016'
OUT=HERE/'local-backfill'
OP='experience-20261016-2216'
def sha(b):return hashlib.sha256(b).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['prepare','apply']);args=parser.parse_args()
    if args.mode=='prepare':
        plan=read(PACKAGE/'source-backfill/plan.json')
        paths=list(plan['files'])+list(plan['preserved'])
        before={n:sha((ROOT/n).read_bytes()) for n in paths}
        expected={'frontend/download.html':'eeb75215b8bcea683202923ff27f5ce5c130e139a94d8a286c90f6dd82576dd4','frontend/downloads/ios/manifest.plist':'059fd04cc113d88e86d91c123715526234d8624342adf94c61d2acfdbea43bf4','frontend/src/admin-home.js':'5a33f4689a1fbd7ad3eb304dbf2b7e0f70f8334491fb9e519152a06935996190'}
        assert all(before[n]==s for n,s in expected.items())
        targets={n:(PACKAGE/item['staged']).read_bytes() for n,item in plan['files'].items()}
        targets['frontend/downloads/ios/manifest.plist']=(PACKAGE/'runtime/hk-snapshot/downloads/ios/manifest.plist').read_bytes()
        admin=(ROOT/'frontend/src/admin-home.js').read_bytes()
        assert admin.count(b'0.4.44')==2 and admin.count(b'2213')==2
        targets['frontend/src/admin-home.js']=admin.replace(b'0.4.44',b'0.4.46').replace(b'2213',b'2215')
        invariant=b'expectedCacheEpoch:adminSession.cacheEpoch(),getCacheEpoch:()=>adminSession.cacheEpoch()'
        assert invariant in targets['frontend/src/admin-home.js']
        for n,item in plan['files'].items():assert sha(targets[n])==item['after']
        OUT.mkdir(exist_ok=False)
        for n in paths:
            p=OUT/'before'/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/n).read_bytes())
        for n,data in targets.items():
            p=OUT/'staged'/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        record={'before':before,'after':{n:sha(b) for n,b in targets.items()},'freeze_sha256':sha((PACKAGE/'freeze-manifest.json').read_bytes()),'scope':'Local source reconciliation only; retain local wallet security additions and exact live iOS identity. No network writes.'}
        (OUT/'plan.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
        print('LOCAL_BACKFILL_PREPARED_NO_SOURCE_WRITE')
    else:
        plan=read(OUT/'plan.json')
        assert not (OUT/'applied.json').exists()
        execution=PACKAGE/'execution'/OP
        pub,audit=read(execution/'publish.json'),read(execution/'audit.json')
        assert pub['status']==audit['status']=='PASS' and pub['result']['status']=='PUBLISH_PASS'
        assert pub['freeze_sha256']==audit['freeze_sha256']==plan['freeze_sha256']
        assert audit['result']['audit_count']==3 and audit['result']['projections']['android']['latest_build']==2216
        assert all(sha((ROOT/n).read_bytes())==s for n,s in plan['before'].items())
        assert all(sha((OUT/'staged'/n).read_bytes())==s for n,s in plan['after'].items())
        for n in plan['after']:(ROOT/n).write_bytes((OUT/'staged'/n).read_bytes())
        assert all(sha((ROOT/n).read_bytes())==s for n,s in plan['after'].items())
        assert all(sha((ROOT/n).read_bytes())==s for n,s in plan['before'].items() if n not in plan['after'])
        (OUT/'applied.json').write_text(json.dumps({'status':'LOCAL_SOURCE_BACKFILL_PASS','files':plan['after'],'publish_sha256':sha((execution/'publish.json').read_bytes()),'audit_sha256':sha((execution/'audit.json').read_bytes())},indent=2)+'\n',encoding='utf-8')
        print('LOCAL_SOURCE_BACKFILL_PASS')
if __name__=='__main__':main()
