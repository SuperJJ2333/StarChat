"""Run the release settings compare/write/readback in one database transaction.

Executed over stdin inside the existing API container by release_metadata.py.
All writes and their audits go through the public SettingService.
"""
import json
import os
import sys

from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import sessionmaker

from app.modules.settings.models import AppSetting
from app.modules.settings.service import (
    APP_IOS_UPDATE_SETTING_KEYS, APP_UPDATE_SETTING_KEYS, SettingService,
)

KEYS = APP_UPDATE_SETTING_KEYS + APP_IOS_UPDATE_SETTING_KEYS
ANDROID_RELEASE_KEYS = {'app_latest_version', 'app_latest_build', 'app_apk_url'}
IOS_RELEASE_KEYS = {'app_ios_latest_version', 'app_ios_latest_build', 'app_ios_download_url'}
NETWORK_DOWNLOAD_ENTRY = 'https://www.liuhetong888.com/download?platform=android&install=1'


def transact_settings(engine, payload):
    mode = payload.get('mode')
    if mode not in ('inspect', 'apply'):
        raise ValueError('invalid settings operation')
    network = payload.get('network_selection', False)
    if type(network) is not bool:
        raise ValueError('network selection must be a boolean')
    if mode == 'apply':
        values = payload.get('values')
        expected = payload.get('expected')
        if (not isinstance(values, dict) or not values
                or any(not isinstance(value, str) for value in values.values())
                or not isinstance(expected, dict) or set(expected) != set(KEYS)):
            raise ValueError('invalid settings handoff')
        if network:
            if set(values) != {'app_apk_url'}:
                raise ValueError('network publication changes download URL only')
            if values['app_apk_url'] != NETWORK_DOWNLOAD_ENTRY:
                raise ValueError('network publication requires the approved download entry')
            release = payload.get('existing_release', {})
            if (not isinstance(release, dict) or not isinstance(release.get('version'), str)
                    or type(release.get('build')) is not int):
                raise ValueError('invalid existing release handoff')
        elif not (set(values) <= ANDROID_RELEASE_KEYS or set(values) <= IOS_RELEASE_KEYS):
            raise ValueError('invalid platform settings keys')
        if not isinstance(payload.get('trace'), str) or not payload['trace']:
            raise ValueError('release trace is required')
        if engine.dialect.name != 'postgresql':
            raise RuntimeError('PostgreSQL is required for atomic release publication')

    # SettingService uses sessions that commit. Binding them to this connection
    # with savepoints keeps their writes/audits inside our outer transaction.
    with engine.begin() as connection:
        if mode == 'apply':
            # Same order as set_many: advisory lock, then rows ordered by key.
            # Row locks also serialize set(), which does not use the advisory lock.
            connection.execute(text('SELECT pg_advisory_xact_lock(1937006964, 1)'))
            existing = set(connection.scalars(select(AppSetting.key)
                .where(AppSetting.key.in_(KEYS)).order_by(AppSetting.key).with_for_update()))
            if network and existing != set(KEYS):
                raise RuntimeError('Update settings rows missing; no write')
        sessions = sessionmaker(bind=connection, autoflush=False, expire_on_commit=False,
                               join_transaction_mode='create_savepoint')
        service = SettingService(sessions)
        before = service.get_many(KEYS)
        if mode == 'inspect':
            return before
        if before != expected:
            raise RuntimeError('Settings drift; no write')
        if network and (before['app_latest_version'] != release['version']
                        or before['app_latest_build'] != str(release['build'])):
            raise RuntimeError('Network publication requires the existing release; no write')
        if any(before[key] != value for key, value in values.items()):
            service.set_many(values, actor_id='ops-release-metadata', trace_id=payload['trace'])
        after = service.get_many(KEYS)
        if after != before | values:
            raise RuntimeError('Settings readback mismatch; transaction rolled back')
        # The outer transaction commits only after the full readback matches.
        return after


def main():
    engine = create_engine(os.environ['BUSINESS_DATABASE_URL'])
    try:
        print(json.dumps(transact_settings(engine, json.loads(sys.argv[1]))))
    finally:
        engine.dispose()


if __name__ == '__main__':
    main()
