"""Read root-owned deployment facts; clients never supply retirement/source evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
from app.core.errors import AppError

POLICY = 'LEGACY_CUSTODY_TO_MANUAL_V1'
FIELDS = {'policy', 'old_mode', 'new_mode', 'old_api_image', 'old_worker_image',
    'old_source_sha256', 'old_config_sha256', 'new_worker_image', 'new_source_sha256',
    'manual_source_identity', 'manual_config_version', 'activation_baseline_at',
    'activation_baseline_height', 'old_monitor_retired_at', 'verified_at'}


def aware(value):
    moment = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise ValueError('aware deployment timestamp required')
    return moment.astimezone(timezone.utc)


def load_deployment(path, *, monitor, now):
    try:
        file = Path(path) if path else None
        if file is None or not file.is_absolute() or file.is_symlink():
            raise ValueError('trusted file required')
        descriptor = os.open(file, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(descriptor, 'rb') as stream:
            stat = os.fstat(stream.fileno())
            if stat.st_size > 65536 or os.name != 'nt' and (stat.st_uid != 0 or stat.st_mode & 0o077):
                raise ValueError('protected deployment file required')
            raw = stream.read(65537)
        record = json.loads(raw)
        if not isinstance(record, dict) or set(record) != FIELDS or record['policy'] != POLICY:
            raise ValueError('invalid deployment record')
        if record['old_mode'] != 'custody_unavailable' or record['new_mode'] != 'manual_tron':
            raise ValueError('invalid handover modes')
        for key in ('old_api_image', 'old_worker_image', 'new_worker_image'):
            if not isinstance(record[key], str) or re.fullmatch('sha256:[a-f0-9]{64}', record[key]) is None:
                raise ValueError('invalid image identity')
        for key in ('old_source_sha256', 'old_config_sha256', 'new_source_sha256', 'manual_source_identity'):
            if not isinstance(record[key], str) or re.fullmatch('[a-f0-9]{64}', record[key]) is None:
                raise ValueError('invalid source identity')
        if (record['manual_source_identity'] != monitor.source.source_identity
                or record['manual_config_version'] != monitor.config.version
                or type(record['activation_baseline_height']) is not int
                or record['activation_baseline_height'] != monitor.baseline_height
                or aware(record['activation_baseline_at']) != monitor.baseline
                or not aware(record['old_monitor_retired_at']) <= aware(record['verified_at']) <= now):
            raise ValueError('deployment runtime mismatch')
        return dict(file_sha256=hashlib.sha256(raw).hexdigest(), record=record)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        raise AppError(code='HANDOVER_DEPLOYMENT_EVIDENCE_UNAVAILABLE',
            message='受控部署证据尚未就绪', status_code=503) from None
