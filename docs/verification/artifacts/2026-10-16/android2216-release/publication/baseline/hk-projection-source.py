
import base64, hashlib, json, os, subprocess
from pathlib import Path
from datetime import datetime, timezone
root=Path('/opt/starchat/frontend')
names=('download.html','downloads/android-release.json','src/admin-home.js','downloads/ios/manifest.plist','src/download-redirect.js','src/download-network.js','src/download-network-selector.js')
files={}
for name in names:
 p=root/name; data=p.read_bytes(); files[name]={'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'base64':base64.b64encode(data).decode()}
registry=json.loads((root/'downloads/android-release.json').read_text())
aliases={p.name:os.readlink(p) for p in (root/'downloads').iterdir() if p.is_symlink()}
old=root/'downloads'/Path(registry['direct_url']).name
h=hashlib.sha256()
with old.open('rb') as f:
 for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
containers=json.loads(subprocess.check_output(['docker','inspect',*subprocess.check_output(['docker','ps','-q'],text=True,timeout=10).split()],text=True,timeout=10))
runtime=[{'name':v['Name'].lstrip('/'),'image':v['Image'],'id':v['Id'],'restart_count':v['RestartCount'],'started_at':v['State']['StartedAt']} for v in containers]
setting_code='''import json,os,hashlib
from pathlib import Path
from sqlalchemy import create_engine,text
from sqlalchemy.orm import sessionmaker
from app.modules.settings.service import SettingService
keys=('app_latest_version','app_latest_build','app_min_supported_build','app_update_notes','app_apk_url','app_ios_latest_version','app_ios_latest_build','app_ios_min_supported_build','app_ios_update_notes','app_ios_download_url')
engine=create_engine(os.environ['BUSINESS_DATABASE_URL'],connect_args={'connect_timeout':3})
try:
 with engine.begin() as connection:
  connection.execute(text('SET TRANSACTION READ ONLY'))
  connection.execute(text("SET LOCAL statement_timeout='5s'"))
  settings=SettingService(sessionmaker(bind=connection,join_transaction_mode='create_savepoint',autoflush=False,expire_on_commit=False)).get_many(keys)
  schema=list(connection.scalars(text('SELECT version_num FROM alembic_version')))
 dependencies={name:hashlib.sha256((Path('/opt/business-api')/name).read_bytes()).hexdigest() for name in ('app/modules/settings/service.py','app/modules/settings/models.py','app/modules/audit/models.py','app/core/database.py')}
 print(json.dumps({'settings':settings,'schema':schema,'settings_dependencies':dependencies},ensure_ascii=False))
finally:engine.dispose()
'''
db=json.loads(subprocess.check_output(['docker','exec','-i','-w','/opt/business-api','starchat-business-api-1','python3','-B','-'],input=setting_code.encode(),timeout=12))
guards={name:hashlib.sha256((Path('/opt/starchat/ops/refresh-guards')/name).read_bytes()).hexdigest() for name in ('business_release_guard.py','business_refresh_image_probe.py')}
print(json.dumps({'permanent_guards':guards,'checked_at_utc':datetime.now(timezone.utc).isoformat(),'files':files,'registry':registry,'aliases':aliases,'old_artifact':{'name':old.name,'bytes':old.stat().st_size,'sha256':h.hexdigest()},'target_exists':(root/'downloads/ChatFlow-0.4.47-build2216-arm64.apk').exists(),'runtime':runtime,**db},ensure_ascii=False))
