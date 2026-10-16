"""Read-only exact route-function projection and release audit verification."""
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

record = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
payload = {'expected': record['deployment']['settings_after'],
           'before': record['deployment']['settings_before'], 'trace': sys.argv[2]}
code = r'''
import json, os, sys
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from app.core.config import Settings
from app.api.app_update import create_app_update_router
from app.modules.settings.service import SettingService
from app.modules.audit.models import AuditEvent

payload = json.loads(sys.argv[1])
engine = create_engine(os.environ['BUSINESS_DATABASE_URL'])
try:
    sessions = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
    actual = SettingService(sessions).get_many(payload['expected'])
    assert actual == payload['expected'], 'ten settings readback drift'
    router = create_app_update_router(Settings(), sessions)
    endpoint = next(route.endpoint for route in router.routes if route.path == '/app-updates/latest')
    projections = {platform: endpoint(platform=platform, user_id='read-only-release-projection') for platform in ('android','ios')}
    for platform, prefix, url_key in (('android','app_','app_apk_url'), ('ios','app_ios_','app_ios_download_url')):
        expected = {'platform':platform, 'configured':True,
            'latest_version':actual[prefix+'latest_version'], 'latest_build':int(actual[prefix+'latest_build']),
            'min_supported_build':int(actual[prefix+'min_supported_build']), 'notes':actual[prefix+'update_notes'],
            'apk_url':actual[url_key], 'download_url':actual[url_key]}
        assert projections[platform] == expected, 'actual route platform projection drift'
    with sessions() as session:
        rows = session.scalars(select(AuditEvent).where(AuditEvent.trace_id == payload['trace'])).all()
        changes = {row.subject_id: ((row.before_data or {}).get('value'),(row.after_data or {}).get('value')) for row in rows}
        expected_changes = {key:(payload['before'][key], value) for key,value in actual.items() if payload['before'][key] != value}
        assert len(rows) == 3 and changes == expected_changes, 'release three-audit readback drift'
        assert all(row.subject_type == 'app_setting' and row.action == 'settings.update' and row.result == 'SUCCESS' and row.reason_code == 'ADMIN_SETTING_UPDATED' and row.actor_id == 'ops-release-metadata' for row in rows), 'release audit identity drift'
    print(json.dumps({'status':'ROUTE_AND_AUDIT_READBACK_PASS', 'projections':projections, 'audit_count':len(rows), 'audit_keys':sorted(changes)}, ensure_ascii=False))
finally:
    engine.dispose()
'''
result = subprocess.check_output(['docker','exec','-i','-w','/opt/business-api',
    'starchat-business-api-1','python3','-',json.dumps(payload)], input=code.encode('utf-8'))
output = json.loads(result)
output['checked_at_utc'] = datetime.now(timezone.utc).isoformat()
print(json.dumps(output, ensure_ascii=False))
