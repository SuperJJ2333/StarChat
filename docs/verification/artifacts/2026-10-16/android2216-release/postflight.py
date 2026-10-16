"""One read-only post-publication preservation check; never repairs state."""
from pathlib import Path
import importlib.util,json,hashlib
H=Path(__file__).resolve().parent
P=H/'publication-final-2216-20261016'
spec=importlib.util.spec_from_file_location('release_executor',H/'publication/execute_release.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
source=(P/'runtime/hk-projection-source.py').read_text(encoding='utf-8')
backup='/opt/starchat/docs/verification/artifacts/2026-10-16/android2216-experience-20261016-2216'
code='import contextlib,io,json,os\nfrom pathlib import Path\ns=io.StringIO()\nwith contextlib.redirect_stdout(s):\n exec('+repr(source)+')\nr=json.loads(s.getvalue())\nb=Path('+repr(backup)+')\nr["backup_mode"]=oct(b.stat().st_mode & 0o777)\nr["backup_result"]=json.loads((b/"result.json").read_text())["status"]\nprint(json.dumps(r))'
before=json.loads((P/'runtime/hk-live-snapshot.json').read_text(encoding='utf-8'))
old=before['old_artifact']['name']
assert old=='ChatFlow-0.4.46-build2215-arm64.apk'
code=code.replace('print(json.dumps(r))','import hashlib\np=Path("/opt/starchat/frontend/downloads")/'+repr(old)+'\nwith p.open("rb") as f: h=hashlib.file_digest(f,"sha256").hexdigest()\nr["previous_immutable"]={"name":p.name,"bytes":p.stat().st_size,"sha256":h}\nprint(json.dumps(r))')
after=m.remote('hk',code,timeout=180)
for key in ('runtime','schema','permanent_guards','settings_dependencies'):
    left,right=before[key],after[key]
    if key=='runtime':left=sorted(left,key=lambda r:r['name']);right=sorted(right,key=lambda r:r['name'])
    assert left==right,key
assert after['previous_immutable']==before['old_artifact']
assert after['old_artifact']['sha256']=='db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039'
assert after['backup_mode']=='0o700' and after['backup_result']=='PUBLISH_PASS'
assert after['settings']['app_latest_build']=='2216' and after['settings']['app_ios_latest_build']=='2215'
expected={**before['settings'],'app_latest_build':'2216','app_latest_version':'0.4.47','app_update_notes':'优化启动和聊天记录加载，完善图片、视频及 GIF 发送预览，恢复超级表情自动播放，改进权限提示体验。'}
assert after['settings']==expected
result={'status':'POSTFLIGHT_PRESERVATION_PASS','checked_at_utc':after['checked_at_utc'],'runtime_count':len(after['runtime']),'runtime_schema_guards_dependencies_old_apk_unchanged':True,'exact_ten_settings_after':True,'backup':backup,'backup_mode':after['backup_mode'],'runtime':after['runtime'],'schema':after['schema']}
with (H/'postflight.json').open('x',encoding='utf-8') as f:json.dump(result,f,indent=2)
print(json.dumps({k:v for k,v in result.items() if k not in ('runtime',)}))
