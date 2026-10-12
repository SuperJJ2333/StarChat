"""Fail-closed reuse of the signed 2214 static lock boundary; never a device gate."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

PREFIXES=('apps/mobile_flutter/android','apps/mobile_flutter/third_party','apps/mobile_flutter/lib/features/calls','apps/mobile_flutter/pubspec.yaml','apps/mobile_flutter/pubspec.lock')
REFERENCE_APK='575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614'
HERE=Path(__file__).resolve().parent

def sha(data):return hashlib.sha256(data).hexdigest()

def canonical_source(name,data,version,build):
    try:data.decode('utf-8')
    except UnicodeDecodeError:return data
    if b'\0' in data:return data
    data=data.replace(b'\r\n',b'\n')
    if name=='apps/mobile_flutter/pubspec.yaml':
        pattern=rb'(?m)^version: '+re.escape(f'{version}+{build}'.encode())+rb'$'
        if len(re.findall(pattern,data))!=1:raise ValueError('approved exact pubspec version required')
        data=re.sub(pattern,b'version: APPROVED_ANDROID_BUILD',data)
    return data

def source_names(repo):
    result=subprocess.run(['git','-C',str(repo),'ls-files','-z','--cached','--others','--exclude-standard','--',*PREFIXES],capture_output=True,check=True,timeout=20)
    names=[x.decode('utf-8') for x in result.stdout.split(b'\0') if x]
    if len(names)!=len(set(names)):raise ValueError('duplicate source names')
    return names

def verify_source(repo,baseline,version='0.4.46',build=2215):
    names=source_names(repo)
    if set(names)!=set(baseline['source_files']):raise ValueError('native/dependency input inventory changed; no reuse')
    for name in names:
        path=repo/name
        if path.is_symlink() or not path.resolve(strict=True).is_relative_to(repo.resolve(strict=True)):raise ValueError('source path escape')
        if sha(canonical_source(name,path.read_bytes(),version,build))!=baseline['source_files'][name]:raise ValueError('lock closure source changed: '+name)
    lock=(repo/'apps/mobile_flutter/pubspec.lock').read_bytes()
    if sha(lock)!=baseline['reference_lock_sha256']:raise ValueError('exact pub.dev lock changed')
    urls=re.findall(rb'(?m)^\s+url:\s*[\"\']?([^\"\'\s]+)',lock)
    if not urls or any(url!=b'https://pub.dev' for url in urls):raise ValueError('hosted dependencies must use pub.dev')
    return len(names)

def decoded_classes(root):
    result={}
    for directory in root.iterdir():
        if not re.fullmatch(r'smali(?:_classes(?:[2-9]|[1-9][0-9]+))?',directory.name):continue
        for path in (directory/'com/liuhetong/mobile').rglob('*.smali'):
            name=path.relative_to(directory).as_posix()
            if path.name.startswith('MainActivity') or name.startswith('com/liuhetong/mobile/call/'):
                if path.is_symlink() or not path.resolve(strict=True).is_relative_to(root.resolve(strict=True)):raise ValueError('decoded path escape')
                if name in result:raise ValueError('duplicate native class across DEX')
                result[name]=sha(path.read_bytes())
    return result

def require_equal_classes(root,expected):
    actual=decoded_classes(root)
    if not expected or actual!=expected:raise ValueError('compiled lock boundary class bytes/inventory changed; no reuse')
    return len(actual)

def normalize_manifest(text,version,build):
    code=f'android:versionCode(0x0101021b)=(type 0x10)0x{build:x}'
    name=f'android:versionName(0x0101021c)="{version}" (Raw: "{version}")'
    if text.count(code)!=1 or text.count(name)!=1:raise ValueError('exact compiled version required')
    text=re.sub(r'(?m)^(\s*E:[^\r\n]* \(line=)\d+(\))$',r'\1LINE\2',text)
    return text.replace(code,'android:versionCode(0x0101021b)=APPROVED_ANDROID_BUILD').replace(name,'android:versionName(0x0101021c)=APPROVED_ANDROID_VERSION')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',required=True,type=Path)
    parser.add_argument('--baseline',required=True,type=Path)
    parser.add_argument('--expected-baseline-sha256',required=True)
    parser.add_argument('--decoded',type=Path)
    parser.add_argument('--manifest',type=Path)
    args=parser.parse_args()
    data=args.baseline.read_bytes()
    if sha(data)!=args.expected_baseline_sha256:raise ValueError('frozen closure baseline hash mismatch')
    baseline=json.loads(data)
    if tuple(baseline['source_prefixes'])!=PREFIXES or baseline['reference_apk_sha256']!=REFERENCE_APK or baseline['reference_apk_bytes']!=73336097:raise ValueError('reference scope/artifact mismatch')
    receipt=(HERE/'historical-lock-boundary.json').read_bytes()
    if sha(receipt)!=baseline['reference_receipt_sha256'] or json.loads(receipt)!=baseline['reference_claims']:raise ValueError('historical receipt mismatch')
    count=verify_source(args.repo,baseline)
    if bool(args.decoded)!=bool(args.manifest):raise ValueError('decoded and manifest required together')
    classes=None
    if args.decoded:
        classes=require_equal_classes(args.decoded,baseline['decoded_class_sha256'])
        text=args.manifest.read_text(encoding='utf-8')
        if sha(normalize_manifest(text,'0.4.46',2215).encode())!=baseline['manifest_normalized_sha256']:raise ValueError('compiled manifest changed beyond approved version/line coordinates; no reuse')
    print(json.dumps({'status':'STATIC_LOCK_CLOSURE_REUSED' if args.decoded else 'SOURCE_LOCK_CLOSURE_EXACT','source_files':count,'decoded_classes':classes,'reference_apk_sha256':REFERENCE_APK,'reference_receipt_sha256':baseline['reference_receipt_sha256'],'candidate_manifest_sha256':sha(args.manifest.read_bytes()) if args.manifest else None,'limits':baseline['limits']},sort_keys=True))

if __name__=='__main__':main()
