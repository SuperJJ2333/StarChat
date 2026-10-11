from pathlib import Path
import csv,datetime,hashlib,json,runpy,struct,subprocess,zipfile
R=Path('C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat')
OUT=Path(__file__).resolve().parent
D=R/'docs/verification/artifacts/2026-10-11/im-reliability-release'
P=R/'docs/verification/artifacts/2026-10-11/android2214-release/final-package-e9d297-r3'
B=D/'android-arm64/run-20261011-175600-r3'
C='e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8'
def sha(d):return hashlib.sha256(d).hexdigest()
def digest(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def git(*a):return subprocess.check_output(['git',*a],cwd=R)
started=datetime.datetime.now(datetime.timezone.utc)
checks=[]
def check(name,ok,detail=None):
 checks.append(dict(check=name,passed=bool(ok),detail=detail))
 if not ok:raise AssertionError(name)
check('freeze exact',digest(P/'freeze-manifest.json')=='b1abd1b18928d8f0306077bc64ff3d09f286b5af11c17a9344f877961abb8297')
m=runpy.run_path(str(P/'orchestrator/execute_release.py'))
f=m['validate_package'](P)
check('package frozen file and runtime tar validation',True,dict(frozen_files=len(f['files']),runtime_files=len(f['runtime_files'])))
a=read(B/'artifact.json');m['package'].validate_source(R,P/'evidence/mobile-inputs.json',a)
check('all source manifest files and lock exact',True,dict(files=a['mobile_file_count'],commit=C,manifest=a['mobile_manifest_sha256']))
for src,dst in [('package_release.py','orchestrator/package_release.py'),('execute_release.py','orchestrator/execute_release.py'),('payload/delivery_2214.py','runtime/delivery_2214.py'),('payload/release_2214.py','runtime/release_2214.py'),('payload/settings_2214.py','runtime/settings_2214.py'),('payload/verify_production_2214.py','runtime/verify_production_2214.py')]:
 blob=git('show','91a5f9f50b6a232686b34adb72e8095954494260:docs/verification/artifacts/2026-10-11/android2214-release/'+src)
 check('previously independently reviewed source '+dst,(P/dst).read_bytes()==blob,sha(blob))
check('build APK equals packaged immutable APK',digest(B/'final.apk')==f['artifact_sha256']==digest(P/'delivery/ChatFlow-0.4.45-build2214-arm64.apk'),dict(bytes=(B/'final.apk').stat().st_size,sha=f['artifact_sha256']))
check('source APK exact',digest(B/'source.apk')==a['source_apk_sha256'],a['source_apk_sha256'])
fg=read(P/'evidence/final-apk.json')
check('bound native static report unchanged',digest(R/'docs/verification/artifacts/2026-10-11/android2214-native-static/native-static-final.json')==fg['native_static_report_sha256'] and read(R/'docs/verification/artifacts/2026-10-11/android2214-native-static/native-static-final.json')==fg['native_static_report'])
check('signature output bound to actual build log',fg['signature_tool_output']==(B/'apksigner-verify.log').read_text(encoding='utf-8-sig') and 'Number of signers: 1' in fg['signature_tool_output'] and 'Verified using v2 scheme (APK Signature Scheme v2): true' in fg['signature_tool_output'] and 'Verified using v3 scheme (APK Signature Scheme v3): true' in fg['signature_tool_output'] and a['signer_sha256']=='75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff')
check('release identity output bound to actual build log',fg['identity_tool_output']==(B/'identity.log').read_text(encoding='utf-8-sig') and "sdkVersion:'24'" in fg['identity_tool_output'] and "targetSdkVersion:'36'" in fg['identity_tool_output'])
check('28 bound build logs',len(fg['steps'])==28 and all(x['exit_code']=='0' and digest(B/x['log'])==x['log_sha256'] and (B/x['log']).stat().st_size==x['log_bytes'] for x in fg['steps']))
summary=read(P/'evidence/shared-flutter.json')
for kind in ('flutter','analyze','boundaries'):
 g=summary['gates'][kind];p=Path(g['receipt']['log']);check('shared '+kind+' actual log',digest(p)==g['log_sha256'] and g['receipt']['exit_code']==0,dict(result=g['result'],log_sha256=digest(p)))
 log=p.read_text(encoding='utf-8-sig');check('shared '+kind+' termination',('All tests passed!' in log if kind=='flutter' else 'No issues found!' in log if kind=='analyze' else '401 passed, 1 skipped' in log))
native=read(P/'evidence/native-android.json');closure=git('diff','--name-only',native['executed_source_commit'],C,'--',*native['unchanged_source_paths']).decode();check('native reuse input closure empty',not closure,dict(executed=native['executed_source_commit'],device=native['device'],real_tests=native['real_tests']))
for name,item in native['evidence'].items():check('native original evidence '+name,digest(item['path'])==item['sha256'])
for name in ('final-apk.json','shared-flutter.json','native-android.json'):
 check('packaged gate matches root '+name,(P/'evidence'/name).read_bytes()==(D/'final-gates-r3'/name).read_bytes())
with zipfile.ZipFile(B/'source.apk') as zs,zipfile.ZipFile(B/'final.apk') as zf:
 check('APK ZIP entry uniqueness',len(zf.namelist())==len(set(zf.namelist())))
 assets=sorted(n for n in zs.namelist() if not n.endswith('/') and n.startswith(('assets/','lib/')))
 check('274 actual native/assets same source to final',len(assets)==274 and all(sha(zs.read(n))==sha(zf.read(n)) for n in assets),len(assets))
 libs=sorted(n for n in zf.namelist() if n.startswith('lib/') and n.endswith('.so'))
 check('14 ARM64 library entries',len(libs)==14 and all(n.startswith('lib/arm64-v8a/') for n in libs),libs)
 baseline=Path('D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-09/android2213-release/delivery/ChatFlow-0.4.44-build2213-arm64.apk')
 check('2213 comparison baseline exact',digest(baseline)=='08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271')
 rows=[]
 with zipfile.ZipFile(baseline) as old, (B/'final.apk').open('rb') as af:
  for n in libs:
   data=zf.read(n);assert data[:6]==b'\x7fELF\x02\x01' and struct.unpack_from('<H',data,18)[0]==183;phoff=struct.unpack_from('<Q',data,32)[0];ents,num=struct.unpack_from('<HH',data,54);assert ents>=56 and num<=256 and phoff+ents*num<=len(data)
   loads=[];relros=[]
   for i in range(num):
    t,flags,offset,vaddr,paddr,filesz,memsz,align=struct.unpack_from('<IIQQQQQQ',data,phoff+i*ents)
    if t==1:loads.append(dict(flags=flags,offset=offset,vaddr=vaddr,filesz=filesz,memsz=memsz,align=align,congruent_16k=(vaddr-offset)%16384==0))
    if t==0x6474e552:relros.append(dict(start=vaddr,end=vaddr+memsz,end_mod_16k=(vaddr+memsz)%16384))
   for rr in relros:
    end=rr['end'];ceil=(end+16383)//16384*16384;rr['tail_writable_intersections']=[dict(start=max(end,x['vaddr']),end=min(ceil,x['vaddr']+x['memsz'])) for x in loads if x['flags']&2 and max(end,x['vaddr'])<min(ceil,x['vaddr']+x['memsz'])]
   info=zf.getinfo(n);af.seek(info.header_offset);header=af.read(30);name_len,extra_len=struct.unpack_from('<HH',header,26);off=info.header_offset+30+name_len+extra_len
   row=dict(path=n,sha256=sha(data),bytes=len(data),matches_2213=data==old.read(n),zip_method=info.compress_type,zip_data_offset=off,zip_16k_aligned=off%16384==0,loads=loads,relro=relros);rows.append(row)
   if n.endswith('/libcrypto.so'):(OUT/'libcrypto-final.so').write_bytes(data)
 check('13 non-libapp native bytes unchanged from 2213',all(x['matches_2213'] for x in rows if not x['path'].endswith('/libapp.so')))
 check('all native stored ZIP16k aligned',all(x['zip_method']==0 and x['zip_16k_aligned'] for x in rows))
 bad_load=[x['path'] for x in rows if any(p['align']<16384 or not p['congruent_16k'] for p in x['loads'])]
 nonzero=[x['path'] for x in rows if any(p['end_mod_16k'] for p in x['relro'])]
 overlap=[x['path'] for x in rows if any(p['tail_writable_intersections'] for p in x['relro'])]
 check('known-only libcrypto PT_LOAD16k failure observed',bad_load==['lib/arm64-v8a/libcrypto.so'],bad_load)
 check('RELRO raw observations agree with limits',len(nonzero)==10 and overlap==['lib/arm64-v8a/libcrypto.so'],dict(nonzero=nonzero,tail_rw_overlap=overlap))
rel=read(P/'runtime/prepared-2214/release.json');dep=rel['deployment'];before=dep['settings_before'];after=dep['settings_after'];changed=sorted(k for k in before if before[k]!=after[k]);check('only three Android settings change',changed==['app_latest_build','app_latest_version','app_update_notes'],changed)
check('minima stay3 and iOS2213 unchanged',before['app_min_supported_build']==after['app_min_supported_build']=='3' and before['app_ios_min_supported_build']==after['app_ios_min_supported_build']=='3' and after['app_ios_latest_build']=='2213')
cf0=dep['cloudfront_before']['DistributionConfig'];cf1=dep['cloudfront_after'];new=json.loads(json.dumps(cf1));item=new['CacheBehaviors']['Items'].pop();new['CacheBehaviors']['Quantity']-=1
check('CF exactly one new behavior',new==cf0 and item['PathPattern']=='downloads/ChatFlow-0.4.45-build2214-arm64.apk' and cf0['CacheBehaviors']['Quantity']==15,dict(before=15,after=cf1['CacheBehaviors']['Quantity'],added=item))
check('bucket policy unchanged',dep['bucket_policy_before']==dep['bucket_policy_after'])
plan=read(P/'source-backfill/plan.json');check('exactly two source-backfill files',set(plan['files'])=={'frontend/download.html','frontend/downloads/android-release.json'})
backfill=[]
for name,v in plan['files'].items():
 local=(R/name).read_bytes();blob=git('show','HEAD:'+name);captured=(P/'runtime/hk-snapshot'/name.removeprefix('frontend/')).read_bytes();target=(P/v['staged']).read_bytes();check('production before and exact reviewed after '+name,sha(captured)==v['before'] and sha(target)==v['after']);check('Git before and local CRLF-only equivalent '+name,blob==captured and (local==captured or (name=='frontend/downloads/android-release.json' and sha(local)=='d551fb5d6dad641cfcc2272571f758973236ec5b49ba60656457298822d83d63' and local.replace(b'\r\n',b'\n')==captured and json.loads(local)==json.loads(captured))))
 backfill.append(dict(path=name,local_raw_sha256=sha(local),local_raw_bytes=len(local),git_blob_sha256=sha(blob),captured_before_sha256=sha(captured),after_sha256=sha(target),rule='After actual publication audit, CAS these exact local raw bytes and unchanged Git blob; copy exact frozen target bytes. Never normalize production before guard.'))
preserved=[]
for name,expected in plan['preserved'].items():
 check('preserved production captured '+name,digest(P/'runtime/hk-snapshot'/name.removeprefix('frontend/'))==expected)
 blob=git('show','HEAD:'+name);raw=(R/name).read_bytes();check('preserved current Git identity equals frozen e9 '+name,blob==git('show',C+':'+name))
 preserved.append(dict(path=name,captured_production_sha256=expected,git_equals_captured=sha(blob)==expected,git_blob_sha256=sha(blob),local_raw_sha256=sha(raw),local_raw_bytes=len(raw),rule='Before and after source backfill recheck Git identity and identical local raw hash; never rewrite preserved files for EOL differences.'))
report=dict(started_utc=started.isoformat(),script_sha256=digest(__file__),created_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),freeze_sha256=digest(P/'freeze-manifest.json'),artifact_sha256=f['artifact_sha256'],source_commit=C,checks=checks,passed=len(checks),failed=0,elf=rows,static_16k_checks_pass=False,runtime_16k_verified=False,backfill=backfill,preserved=preserved,scope='Independent read-only source/artifact/evidence/package inspection; no rebuild, server execution, device run or publication.')
(OUT/'independent-evidence.json').write_bytes((json.dumps(report,ensure_ascii=False,indent=2)+'\n').encode())
print(json.dumps(dict(passed=len(checks),failed=0,source_files=a['mobile_file_count'],native_libraries=len(rows),elf_16k_failures=bad_load,relro_nonzero_count=len(nonzero),relro_rw_overlap=overlap,backfill=backfill),ensure_ascii=False))
