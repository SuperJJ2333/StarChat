"""Read-only, bounded prefix inventory. Counts are observations, never an atomic snapshot."""
from datetime import datetime, timezone
import hashlib
import re
from time import monotonic

from botocore.exceptions import BotoCoreError, ClientError

from app.integrations.media_storage_metrics import classify_storage_error, observe_storage

_DOMAINS = ('business', 'synapse')
_MEDIA_ROOTS = {'business': ('media/', 'moments/', 'avatars/', 'files/', 'system/'),
    'synapse': ('local_content/', 'remote_content/', 'local_thumbnails/', 'remote_thumbnails/',
                'url_cache/', 'url_cache_thumbnails/')}


@observe_storage('s3', 'list')
def _list(client, **kwargs):
    return client.list_objects_v2(**kwargs)


def collect_storage_capacity(*, client, bucket: str, max_pages: int = 1000,
                             page_size: int = 1000, max_seconds: float = 30) -> dict:
    if (not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket)
            or type(max_pages) is not int or not 1 <= max_pages <= 10000
            or type(page_size) is not int or not 1 <= page_size <= 1000
            or type(max_seconds) not in (int, float) or not 0 < max_seconds <= 300):
        raise ValueError('storage capacity scan configuration invalid')
    started = monotonic()
    report = {'coverage': 'INCOMPLETE', 'non_atomic': True,
        'listing_scope': 'current_objects_only', 'noncurrent_versions_included': False,
        'multipart_uploads_included': False,
        'started_at': datetime.now(timezone.utc).isoformat(), 'pages': 0,
        'object_count': 0, 'bytes': 0, 'domains': {}}
    for domain in _DOMAINS:
        prefix = domain + '/'
        counts = {'coverage': 'INCOMPLETE', 'pages': 0, 'object_count': 0, 'bytes': 0,
            'media_object_count': 0, 'media_bytes': 0, 'fence_object_count': 0,
            'fence_bytes': 0, 'other_object_count': 0, 'other_bytes': 0}
        report['domains'][domain] = counts
        token, seen = None, set()
        while report['pages'] < max_pages and monotonic() - started < max_seconds:
            kwargs = {'Bucket': bucket, 'Prefix': prefix, 'MaxKeys': page_size}
            if token is not None:
                kwargs['ContinuationToken'] = token
            report['pages'] += 1
            counts['pages'] += 1
            try:
                response = _list(client, **kwargs)
                items = response.get('Contents', [])
                truncated = response.get('IsTruncated')
                if not isinstance(items, list) or len(items) > page_size or type(truncated) is not bool:
                    raise ValueError('invalid capacity page')
                page_counts = {'media': [0, 0], 'fence': [0, 0], 'other': [0, 0]}
                for item in items:
                    key, size = item.get('Key'), item.get('Size')
                    if not isinstance(key, str) or not key.startswith(prefix) or type(size) is not int or size < 0:
                        raise ValueError('invalid capacity object metadata')
                    suffix = key[len(prefix):]
                    category = ('fence' if domain == 'synapse' and suffix.startswith('lifecycle_deleted/')
                        else 'media' if suffix.startswith(_MEDIA_ROOTS[domain]) else 'other')
                    page_counts[category][0] += 1
                    page_counts[category][1] += size
                next_token = response.get('NextContinuationToken') if truncated else None
                if truncated:
                    if not isinstance(next_token, str) or not next_token or len(next_token) > 8192:
                        raise ValueError('invalid capacity continuation')
                    digest = hashlib.sha256(next_token.encode()).digest()
                    if digest in seen:
                        raise ValueError('repeated capacity continuation')
                    seen.add(digest)
                # Commit a page's totals only after all metadata/cursor validation passes.
                for category, (objects, size) in page_counts.items():
                    counts[f'{category}_object_count'] += objects
                    counts[f'{category}_bytes'] += size
                    counts['object_count'] += objects
                    counts['bytes'] += size
                    report['object_count'] += objects
                    report['bytes'] += size
                if not truncated:
                    counts['coverage'] = 'COMPLETE_BOUNDED_LISTING'
                    break
                token = next_token
            except (BotoCoreError, ClientError, OSError, TimeoutError, ValueError, TypeError, AttributeError) as error:
                counts['coverage'] = 'ERROR'
                counts['error'] = classify_storage_error(error)
                break
    states = [counts['coverage'] for counts in report['domains'].values()]
    report['coverage'] = ('ERROR' if 'ERROR' in states else 'COMPLETE_BOUNDED_LISTING'
        if all(state == 'COMPLETE_BOUNDED_LISTING' for state in states) else 'INCOMPLETE')
    report['finished_at'] = datetime.now(timezone.utc).isoformat()
    report['elapsed_ms'] = round((monotonic() - started) * 1000, 3)
    return report
