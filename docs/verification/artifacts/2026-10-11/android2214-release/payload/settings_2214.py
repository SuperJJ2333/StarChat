"""Run over stdin in the existing API container; never write AppSetting directly."""
import json
import os
import re
import sys

NOTES = '改进发送队列、历史加载和媒体缓存，增加媒体任务恢复和大小预检，优化Android后台运行稳定性。当前普通附件最高48MiB，图片因解码预算上限更低；过大时请压缩或缩小后重试。'
INSTALL='https://www.liuhetong888.com/download?platform=android&install=1'
IOS_INSTALL='https://www.liuhetong888.com/download?platform=ios&install=1'
KEYS=('app_latest_version','app_latest_build','app_min_supported_build','app_update_notes','app_apk_url',
      'app_ios_latest_version','app_ios_latest_build','app_ios_min_supported_build','app_ios_update_notes','app_ios_download_url')

def validate(payload):
    if set(payload) != {'mode','expected','after','trace'} or payload['mode'] not in ('inspect','apply'):
        raise ValueError('invalid settings operation')
    before,after=payload['expected'],payload['after']
    if not isinstance(before,dict) or set(before)!=set(KEYS) or any(not isinstance(v,str) or not v for v in before.values()):
        raise ValueError('exact ten-setting baseline required')
    fixed={'app_latest_version':'0.4.44','app_latest_build':'2213','app_min_supported_build':'3','app_apk_url':INSTALL,
           'app_ios_latest_version':'0.4.44','app_ios_latest_build':'2213','app_ios_min_supported_build':'3','app_ios_download_url':IOS_INSTALL}
    if any(before[k]!=v for k,v in fixed.items()):raise ValueError('2213 settings baseline drift')
    values={'app_latest_version':'0.4.45','app_latest_build':'2214','app_update_notes':NOTES}
    if after!=before|values:raise ValueError('only exact Android version/build/notes change allowed')
    if payload['mode']=='apply' and (not isinstance(payload['trace'],str) or not re.fullmatch('[A-Za-z0-9_.:-]{8,100}',payload['trace'])):
        raise ValueError('unique audit trace required')
    return values

def transact(engine,payload):
    values=validate(payload)
    from sqlalchemy import select,text
    from sqlalchemy.orm import sessionmaker
    from app.modules.settings.models import AppSetting
    from app.modules.settings.service import SettingService
    from app.modules.audit.models import AuditEvent
    applying=payload['mode']=='apply'
    if applying and engine.dialect.name!='postgresql':raise RuntimeError('PostgreSQL required')
    with engine.begin() as connection:
        if applying:
            connection.execute(text('SELECT pg_advisory_xact_lock(1937006964, 1)'))
            existing=set(connection.scalars(select(AppSetting.key).where(AppSetting.key.in_(KEYS)).order_by(AppSetting.key).with_for_update()))
            if existing!=set(KEYS):raise RuntimeError('settings rows missing; no write')
        sessions=sessionmaker(bind=connection,autoflush=False,expire_on_commit=False,join_transaction_mode='create_savepoint')
        service=SettingService(sessions)
        before=service.get_many(KEYS)
        if not applying:return before
        if before!=payload['expected']:raise RuntimeError('ten-key CAS drift; no write')
        with sessions() as session:
            if session.scalar(select(AuditEvent.id).where(AuditEvent.trace_id==payload['trace']).limit(1)) is not None:
                raise RuntimeError('audit trace already exists; inspect rather than replay')
        service.set_many(values,actor_id='ops-release-metadata',trace_id=payload['trace'])
        after=service.get_many(KEYS)
        if after!=payload['after']:raise RuntimeError('readback differs; rollback outer transaction')
        with sessions() as session:
            rows=session.scalars(select(AuditEvent).where(AuditEvent.trace_id==payload['trace'])).all()
            actual={r.subject_id:((r.before_data or {}).get('value'),(r.after_data or {}).get('value')) for r in rows}
            expected={k:(before[k],v) for k,v in values.items() if before[k]!=v}
            if len(rows)!=len(expected) or actual!=expected or any(r.subject_type!='app_setting' or r.action!='settings.update' or r.result!='SUCCESS' or r.reason_code!='ADMIN_SETTING_UPDATED' for r in rows):
                raise RuntimeError('audit differs; rollback outer transaction')
        return after

if __name__=='__main__':
    from sqlalchemy import create_engine
    engine=create_engine(os.environ['BUSINESS_DATABASE_URL'])
    try:print(json.dumps(transact(engine,json.loads(sys.argv[1])),ensure_ascii=False))
    finally:engine.dispose()
