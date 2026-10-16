"""Bind real build and reused test evidence; refuse missing/changed inputs."""
from pathlib import Path
import csv, hashlib, json, subprocess, zipfile
from datetime import datetime, timezone

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[4]
BUILD=HERE/'arm64-final'
OUT=HERE/'gates'
AUTO=ROOT/'docs/verification/artifacts/2026-10-16/super-emoji-autoplay'
EXP=ROOT/'docs/verification/artifacts/2026-10-16/mobile-experience-2216'
PENDING={}
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def write(name,data):
    content=(json.dumps(data,ensure_ascii=False,indent=2)+'\n').encode('utf-8')
    PENDING[name]=content
    return {'status':'pass','path':name,'sha256':hashlib.sha256(content).hexdigest()}
def evidence(p):return {'path':p.relative_to(ROOT).as_posix(),'sha256':sha(p),'bytes':p.stat().st_size}
def diff(commit,target,*paths):
    return subprocess.check_output(['git','-C',str(ROOT),'diff','--name-only',commit,target,'--',*paths],text=True).splitlines()

def main():
    a=read(BUILD/'receipt.json')
    assert a['status']=='PASS' and a['build']==2216
    assert a['final_apk_sha256']==sha(BUILD/'final.apk')
    assert a['mobile_manifest_sha256']==sha(BUILD/'mobile-inputs.json')
    assert (a['version'],a['package'],a['abi'],a['target'])==('0.4.47','com.liuhetong.mobile','arm64-v8a','lib/main.dart')
    assert a['source_commit']==read(BUILD/'mobile-inputs.json')['source_commit']==read(BUILD/'freeze-input.log')['source_commit']
    assert a['mobile_manifest_sha256']==read(BUILD/'freeze-input.log')['manifest_sha256']
    rows=list(csv.DictReader((BUILD/'steps.tsv').open(encoding='utf-8'),delimiter='\t'))
    expected=['pub-get','freeze-input','registrant-correction','source-build','source-release-payload','source-assets','original-manifest','decode','rebuild','align','sign','signature','alignment','identity','final-release-payload','final-assets','frozen-after','rebuilt-manifest','verify-decode','rebuild-verification']
    assert [x['step'] for x in rows]==expected
    assert all(x['exit_code']=='0' for x in rows)
    shared=read(AUTO/'full-host/receipt.json'); summary=read(AUTO/'full-host/summary.json')
    assert shared['exit_code']==0 and summary['done']['success'] and summary['counts']=={'success':6038,'skip':9}
    assert not diff(shared['source_commit'],a['source_commit'],'apps/mobile_flutter')
    assert shared['lock_sha256']==a['pubspec_lock_sha256']
    runtime=read(AUTO/'runtime-acceptance.json')
    assert runtime['status']=='PASS' and not diff(runtime['source_commit'],a['source_commit'],'apps/mobile_flutter')
    native=read(EXP/'android-native-corrected-runtime/receipt.json')
    assert native['driver_exit_code']==0 and 'All tests passed.' in (EXP/'android-native-corrected-runtime/driver.log').read_text()
    changed=diff(native['source_commit'],a['source_commit'],'apps/mobile_flutter')
    assert set(changed)==set(['apps/mobile_flutter/lib/ui/chat/emoji_resource_glyph.dart','apps/mobile_flutter/lib/ui/chat/super_emoji_message.dart','apps/mobile_flutter/test/shared_emoji_player_test.dart','apps/mobile_flutter/test/ui/super_emoji_message_test.dart'])
    binding={k:a[v] for k,v in [('source_commit','source_commit'),('source_manifest_sha256','mobile_manifest_sha256'),('pubspec_lock_sha256','pubspec_lock_sha256'),('artifact_sha256','final_apk_sha256')]}
    checks={}
    checks['shared_flutter']=write('shared_flutter.json',{'status':'pass','binding':binding,'reused':True,'receipt':shared,'summary':summary,'mobile_diff':[], 'evidence':[evidence(AUTO/'full-host/receipt.json'),evidence(AUTO/'full-host/summary.json'),evidence(AUTO/'full-host/flutter-full.log')], 'limitations':['Global verify.ps1 lacks local .env; not all-repository PASS']})
    checks['native_android']=write('native_android.json',{'status':'pass','binding':binding,'scope':'API28 x86_64 actual-main autoplay and synthetic native integration; not ARM64 phone acceptance','actual_main':runtime,'native_driver':native,'changed_since_native':changed,'reuse_reason':'Native test/runtime modules and dependencies unchanged; two emoji widget changes independently exercised on actual-main final revision','evidence':[evidence(AUTO/'runtime-acceptance.json'),evidence(AUTO/'install-autoplay/receipt.json'),evidence(EXP/'android-native-corrected-runtime/receipt.json'),evidence(EXP/'android-native-corrected-runtime/driver.log')],'limitations':['Null reportData from native driver is not individual per-case metrics; driver exit0 and All tests passed are retained','No ARM64 phone, broad ROM, weak-network or 16KiB-device acceptance']})
    previous=ROOT/'docs/verification/artifacts/2026-10-12/android2215-release-candidate/run-20261012-132000/final.apk'
    assert sha(previous)=='4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6'
    def libs(path):
        with zipfile.ZipFile(path) as z:return {n:hashlib.sha256(z.read(n)).hexdigest() for n in z.namelist() if n.startswith('lib/') and n.endswith('.so')}
    old,new,source=libs(previous),libs(BUILD/'final.apk'),libs(BUILD/'source.apk')
    assert new==source and new.keys()==old.keys()
    delta=[n for n in new if new[n]!=old[n]]
    assert delta==['lib/arm64-v8a/libapp.so'],delta
    report=read(HERE/'native-static.json')
    assert report['source']['sha256']==sha(BUILD/'source.apk') and report['final']['sha256']==a['final_apk_sha256']
    assert report['source']['bytes']==(BUILD/'source.apk').stat().st_size and report['final']['bytes']==a['final_apk_bytes']
    inspector=read(HERE/'native-inspection-receipt.json')
    assert inspector['exit_code']==1 and not report['static_16k_checks_pass'] and report['known_libcrypto_load_alignment_p1_retained']
    oldreport=read(ROOT/'docs/verification/artifacts/2026-10-12/android2215-final-independent-review/native/native-static-2215.json')
    assert report['matrix_symbols']==oldreport['matrix_symbols']
    assert report['final_elf_load_failures']==oldreport['final_elf_load_failures'] and report['final_elf_relro_end_nonzero_observations']==oldreport['final_elf_relro_end_nonzero_observations']
    assert not report['final_zip_stored_alignment_failures']
    logs=[BUILD/n for n in ['receipt.json','steps.tsv','source-build.log','source-release-payload.log','source-assets.log','signature.log','alignment.log','identity.log','final-release-payload.log','final-assets.log','rebuild-verification.log','frozen-after.log']]+[HERE/'native-inspection-receipt.json']
    checks['final_apk']=write('final_apk.json',{'status':'pass','binding':binding,'receipt':a,'steps':rows,'native_libraries':new,'changed_native_libraries':delta,'source_final_native_identical':True,'matrix_symbol_contract_unchanged':True,'evidence':[evidence(p) for p in logs]+[evidence(HERE/'native-static.json')],'limitations':['Existing libcrypto ELF16KiB/RELRO risk remains; native inspector exit1 is retained, not 16KiBPASS','Release APK not installed on ARM64 phone; emulator used matching-source Debug']})
    write('gates.json',{**binding,'final_identity':{'package':a['package'],'abi':a['abi'],'version':a['version'],'build':a['build'],'signer_sha256':a['signer_sha256'],'artifact_bytes':a['final_apk_bytes']},'checks':checks,'collected_at':datetime.now(timezone.utc).isoformat()})
    OUT.mkdir(exist_ok=False)
    for name,content in PENDING.items():(OUT/name).write_bytes(content)
    print(json.dumps({'status':'BOUND_EVIDENCE_PASS','artifact_sha256':a['final_apk_sha256'],'changed_native_libraries':delta}))
if __name__=='__main__':main()
