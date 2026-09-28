"""Server-only S3 bytes and migration-compatible reads; URLs remain business URLs."""
from __future__ import annotations

import base64
import json
import hashlib
from io import BytesIO
import re
from urllib.parse import urlparse

from botocore.exceptions import BotoCoreError, ClientError

from app.core.errors import AppError
from app.integrations.media_storage_metrics import (
    classify_storage_error, observe_storage, storage_backend_metrics,
)
from app.modules.media.storage import LocalBlobBackend, ObjectPage

_ROOTS = frozenset(('media', 'moments', 'avatars', 'files', 'system'))


def _invalid_key() -> None:
    raise AppError(code='MEDIA_STORAGE_KEY_INVALID', message='媒体存储引用无效', status_code=500)


def _validate_key(key: str) -> None:
    parts = key.split('/')
    if (not key or '\\' in key or any(ord(char) < 32 for char in key)
            or len(parts) < 2 or parts[0] not in _ROOTS
            or any(part in ('', '.', '..') for part in parts)):
        _invalid_key()


def _validate_prefix(prefix: str) -> None:
    if not prefix.endswith('/'):
        _invalid_key()
    _validate_key(prefix + 'listing')


def _unavailable(error=None, *, outcome='invalid') -> AppError:
    sanitized = AppError(code='MEDIA_STORAGE_UNAVAILABLE', message='媒体存储暂时不可用', status_code=503)
    sanitized._storage_metrics_outcome = classify_storage_error(error) if error is not None else outcome
    return sanitized


def _object_missing(error: ClientError) -> bool:
    response = error.response
    return (response.get('ResponseMetadata', {}).get('HTTPStatusCode') == 404
            and response.get('Error', {}).get('Code') in ('NoSuchKey', '404', 'NotFound'))


class S3BlobBackend:
    def __init__(self, *, bucket: str, region: str, prefix: str = 'business/',
                 endpoint: str | None = None, client=None,
                 max_object_bytes: int = 64 * 1024 * 1024) -> None:
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('S3 bucket name invalid')
        if not region:
            raise ValueError('S3 region required')
        if (not prefix or not prefix.endswith('/') or prefix.startswith('/')
                or '\\' in prefix or any(part in ('', '.', '..') for part in prefix[:-1].split('/'))):
            raise ValueError('S3 prefix invalid')
        self._bucket, self._prefix = bucket, prefix
        if type(max_object_bytes) is not int or not 1 <= max_object_bytes <= 512 * 1024 * 1024:
            raise ValueError('S3 object read bound invalid')
        self._max_object_bytes = max_object_bytes
        if client is None:
            if endpoint:
                parsed = urlparse(endpoint)
                if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
                        or parsed.query or parsed.fragment or parsed.path not in ('', '/')):
                    raise ValueError('S3 endpoint must be a verified HTTPS origin')
            import boto3
            from botocore.config import Config
            # No credentials arguments: use the standard refreshable credential chain.
            client = boto3.client('s3', region_name=region, endpoint_url=endpoint,
                config=Config(connect_timeout=3, read_timeout=15,
                    retries={'mode': 'standard', 'total_max_attempts': 3},
                    max_pool_connections=20))
        self._client = client

    @observe_storage('s3', 'put')
    def put(self, key: str, content: bytes) -> None:
        _validate_key(key)
        if len(content) > self._max_object_bytes:
            raise _unavailable()
        try:
            # PutObject publishes a complete object atomically; no staging key is exposed.
            self._client.put_object(Bucket=self._bucket, Key=self._prefix + key,
                Body=content, ServerSideEncryption='AES256',
                ChecksumSHA256=base64.b64encode(hashlib.sha256(content).digest()).decode('ascii'))
        except (BotoCoreError, ClientError, OSError, TimeoutError) as error:
            raise _unavailable(error) from None

    @observe_storage('s3', 'get')
    def get(self, key: str) -> bytes:
        _validate_key(key)
        try:
            response = self._client.get_object(Bucket=self._bucket, Key=self._prefix + key,
                                               ChecksumMode='ENABLED')
            body = response['Body']
            try:
                length = response.get('ContentLength')
                if type(length) is not int or not 0 <= length <= self._max_object_bytes:
                    raise _unavailable()
                output = BytesIO()
                digest = hashlib.sha256()
                while True:
                    chunk = body.read(min(1024 * 1024, self._max_object_bytes + 1 - output.tell()))
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    if output.tell() > self._max_object_bytes:
                        raise _unavailable()
                if output.tell() != length:
                    raise _unavailable()
                checksum = response.get('ChecksumSHA256')
                if checksum and response.get('ChecksumType', 'FULL_OBJECT') == 'FULL_OBJECT':
                    if checksum != base64.b64encode(digest.digest()).decode('ascii'):
                        raise _unavailable()
                return output.getvalue()
            finally:
                body.close()
        except ClientError as error:
            if _object_missing(error):
                raise AppError(code='MEDIA_BLOB_MISSING', message='媒体文件不存在', status_code=503) from None
            raise _unavailable(error) from None
        except (BotoCoreError, OSError, TimeoutError) as error:
            raise _unavailable(error) from None

    @observe_storage('s3', 'exists')
    def exists(self, key: str) -> bool:
        _validate_key(key)
        try:
            self._client.head_object(Bucket=self._bucket, Key=self._prefix + key)
            return True
        except ClientError as error:
            if _object_missing(error):
                return False
            raise _unavailable(error) from None
        except (BotoCoreError, OSError, TimeoutError) as error:
            raise _unavailable(error) from None

    @observe_storage('s3', 'delete')
    def delete(self, key: str) -> None:
        _validate_key(key)
        try:
            self._client.delete_object(Bucket=self._bucket, Key=self._prefix + key)
        except (BotoCoreError, ClientError, OSError, TimeoutError) as error:
            raise _unavailable(error) from None

    @observe_storage('s3', 'list')
    def list_page(self, *, prefix: str, limit: int = 1000, cursor: str | None = None) -> ObjectPage:
        _validate_prefix(prefix)
        if not 1 <= limit <= 1000:
            raise ValueError('object page size must be 1-1000')
        arguments = dict(Bucket=self._bucket, Prefix=self._prefix + prefix, MaxKeys=limit)
        if cursor is not None:
            if not isinstance(cursor, str) or not cursor or len(cursor) > 8192:
                _invalid_key()
            arguments['ContinuationToken'] = cursor
        try:
            response = self._client.list_objects_v2(**arguments)
        except (BotoCoreError, ClientError, OSError, TimeoutError) as error:
            raise _unavailable(error) from None
        keys = []
        for item in response.get('Contents', ()):
            stored = item.get('Key', '')
            if not stored.startswith(self._prefix + prefix):
                raise _unavailable()
            key = stored[len(self._prefix):]
            _validate_key(key)
            if not key.endswith('.tmp'):
                keys.append(key)
        next_cursor = response.get('NextContinuationToken') if response.get('IsTruncated') else None
        if response.get('IsTruncated') and not next_cursor:
            raise _unavailable()
        return ObjectPage(tuple(keys), next_cursor)


class DualReadBlobBackend:
    """One write authority. Only a definite miss consults the older store."""
    def __init__(self, *, primary, fallback) -> None:
        self.primary, self.fallback = primary, fallback

    @observe_storage('dual', 'put')
    def put(self, key: str, content: bytes) -> None:
        self.primary.put(key, content)

    @observe_storage('dual', 'get')
    def get(self, key: str) -> bytes:
        try:
            return self.primary.get(key)
        except AppError as error:
            if error.code != 'MEDIA_BLOB_MISSING':
                raise
            storage_backend_metrics.fallback('get')
            return self.fallback.get(key)

    @observe_storage('dual', 'exists')
    def exists(self, key: str) -> bool:
        if self.primary.exists(key):
            return True
        storage_backend_metrics.fallback('exists')
        return self.fallback.exists(key)

    @observe_storage('dual', 'delete')
    def delete(self, key: str) -> None:
        # A failure is visible to the caller; GC keeps its durable RETIRING state.
        self.primary.delete(key)
        self.fallback.delete(key)

    @observe_storage('dual', 'list')
    def list_page(self, *, prefix: str, limit: int = 1000, cursor: str | None = None) -> ObjectPage:
        _validate_prefix(prefix)
        phase, position = 0, None
        if cursor is not None:
            try:
                if not isinstance(cursor, str) or len(cursor) > 32768:
                    _invalid_key()
                state = json.loads(base64.urlsafe_b64decode(cursor.encode('ascii')))
                if set(state) != {'phase', 'position', 'prefix'} or state['prefix'] != prefix:
                    _invalid_key()
                phase, position = state['phase'], state['position']
                if type(phase) is not int or phase not in (0, 1):
                    _invalid_key()
                if position is not None and (not isinstance(position, str) or len(position) > 8192):
                    _invalid_key()
            except (ValueError, TypeError, KeyError, UnicodeError):
                _invalid_key()
        store = self.primary if phase == 0 else self.fallback
        if phase == 1:
            storage_backend_metrics.fallback('list')
        page = store.list_page(prefix=prefix, limit=limit, cursor=position)
        if page.next_cursor is not None:
            next_phase, next_position = phase, page.next_cursor
        elif phase == 0:
            next_phase, next_position = 1, None
        else:
            return page
        state = {'phase': next_phase, 'position': next_position, 'prefix': prefix}
        token = base64.urlsafe_b64encode(json.dumps(state, separators=(',', ':')).encode()).decode('ascii')
        return ObjectPage(page.keys, token)


def build_blob_backend(settings, *, client=None):
    local = LocalBlobBackend(root=settings.avatar_storage_root)
    mode = settings.media_blob_backend
    if mode == 'local':
        return local
    remote = S3BlobBackend(bucket=settings.media_s3_bucket, region=settings.media_s3_region,
        prefix=settings.media_s3_prefix, endpoint=settings.media_s3_endpoint, client=client,
        max_object_bytes=settings.media_s3_max_object_bytes)
    if mode == 's3':
        return DualReadBlobBackend(primary=remote, fallback=local)
    if mode == 'local_s3_read':
        return DualReadBlobBackend(primary=local, fallback=remote)
    raise ValueError('media backend mode invalid')
