"""Byte-store contract; the fake transport models S3 errors, not authorization."""
from io import BytesIO
import base64
import hashlib
import importlib
import importlib.util

import pytest
from botocore.exceptions import ClientError, EndpointConnectionError

from app.core.config import Settings
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.media.storage import LocalBlobBackend


def implementation():
    name = 'app.integrations.media_blob_storage'
    assert importlib.util.find_spec(name) is not None, 'S3 media backend is not implemented'
    return importlib.import_module(name)


class S3Transport:
    def __init__(self):
        self.objects = {}
        self.calls = []
        self.failure = None

    def _call(self, operation, values):
        self.calls.append((operation, values))
        if self.failure is not None:
            raise self.failure

    def put_object(self, **values):
        self._call('put', values)
        self.objects[values['Key']] = values['Body']

    def get_object(self, **values):
        self._call('get', values)
        if values['Key'] not in self.objects:
            raise client_error('NoSuchKey', 404)
        content = self.objects[values['Key']]
        return {'Body': BytesIO(content), 'ContentLength': len(content),
                'ChecksumSHA256': base64.b64encode(hashlib.sha256(content).digest()).decode(),
                'ChecksumType': 'FULL_OBJECT'}

    def head_object(self, **values):
        self._call('head', values)
        if values['Key'] not in self.objects:
            raise client_error('404', 404)
        return {'ContentLength': len(self.objects[values['Key']])}

    def delete_object(self, **values):
        self._call('delete', values)
        self.objects.pop(values['Key'], None)

    def list_objects_v2(self, **values):
        self._call('list', values)
        keys = sorted(key for key in self.objects if key.startswith(values['Prefix']))
        start = int(values.get('ContinuationToken', '0'))
        count = values['MaxKeys']
        result = {'Contents': [{'Key': key} for key in keys[start:start + count]],
                  'IsTruncated': start + count < len(keys)}
        if result['IsTruncated']:
            result['NextContinuationToken'] = str(start + count)
        return result


def client_error(code, status):
    return ClientError({'Error': {'Code': code}, 'ResponseMetadata': {'HTTPStatusCode': status}}, 'GetObject')


def backend(transport=None):
    return implementation().S3BlobBackend(bucket='unit-bucket', region='ap-east-1',
        prefix='business/', client=transport or S3Transport())


def test_s3_atomic_put_get_exists_delete_and_sse():
    transport = S3Transport()
    store = backend(transport)
    assert not store.exists('avatars/u/image.png')
    store.put('avatars/u/image.png', b'opaque media')
    assert store.get('avatars/u/image.png') == b'opaque media'
    assert store.exists('avatars/u/image.png')
    assert transport.calls[1][1]['ServerSideEncryption'] == 'AES256'
    store.delete('avatars/u/image.png')
    store.delete('avatars/u/image.png')
    assert not store.exists('avatars/u/image.png')
    with pytest.raises(AppError) as caught:
        store.get('avatars/u/image.png')
    assert caught.value.code == 'MEDIA_BLOB_MISSING'


@pytest.mark.parametrize('key', ['', '/media/a', '../media/a', 'media/../a', 'media//a', 'media/./a',
                                 'media\\a', 'elsewhere/a', 'media/a\x00'])
def test_s3_rejects_prefix_escape_without_network(key):
    transport = S3Transport()
    store = backend(transport)
    with pytest.raises(AppError):
        store.get(key)
    assert transport.calls == []


@pytest.mark.parametrize('error', [client_error('AccessDenied', 403), client_error('NoSuchBucket', 404),
    client_error('SlowDown', 503), client_error('InternalError', 500),
    EndpointConnectionError(endpoint_url='https://s3.example.invalid')])
def test_s3_outage_and_permissions_never_become_object_missing(error):
    transport = S3Transport()
    transport.failure = error
    store = backend(transport)
    for operation in (store.get, store.exists):
        with pytest.raises(AppError) as caught:
            operation('media/user/scope/blob.bin')
        assert caught.value.code == 'MEDIA_STORAGE_UNAVAILABLE'
        assert 's3.example' not in caught.value.message


def test_s3_listing_is_prefix_limited_and_resumable():
    transport = S3Transport()
    store = backend(transport)
    for number in range(5):
        store.put(f'media/user/scope/{number}.bin', b'x')
    transport.objects['synapse/local_content/private'] = b'outside'
    page = store.list_page(prefix='media/', limit=2)
    assert len(page.keys) == 2 and page.next_cursor is not None
    next_page = store.list_page(prefix='media/', limit=2, cursor=page.next_cursor)
    assert not set(page.keys) & set(next_page.keys)
    assert all(key.startswith('media/') for key in (*page.keys, *next_page.keys))
    assert transport.calls[-1][1]['MaxKeys'] == 2
    with pytest.raises(AppError):
        store.list_page(prefix='', limit=100)


def test_dual_read_single_write_and_rollback_keeps_s3_only_objects(tmp_path):
    local = LocalBlobBackend(root=str(tmp_path))
    remote = backend()
    local.put('avatars/u/old.png', b'old')
    dual = implementation().DualReadBlobBackend(primary=remote, fallback=local)
    assert dual.get('avatars/u/old.png') == b'old'
    dual.put('avatars/u/new.png', b'new')
    assert not local.exists('avatars/u/new.png')
    rollback = implementation().DualReadBlobBackend(primary=local, fallback=remote)
    assert rollback.get('avatars/u/new.png') == b'new'
    rollback.put('avatars/u/rollback.png', b'local')
    assert not remote.exists('avatars/u/rollback.png')
    dual.delete('avatars/u/old.png')
    assert not local.exists('avatars/u/old.png')


def test_dual_read_does_not_hide_outage_and_delete_failure_is_visible(tmp_path):
    local = LocalBlobBackend(root=str(tmp_path))
    local.put('media/user/scope/blob.bin', b'old')
    transport = S3Transport()
    remote = backend(transport)
    dual = implementation().DualReadBlobBackend(primary=remote, fallback=local)
    transport.failure = client_error('AccessDenied', 403)
    for operation in (dual.get, dual.exists, dual.delete):
        with pytest.raises(AppError) as caught:
            operation('media/user/scope/blob.bin')
        assert caught.value.code == 'MEDIA_STORAGE_UNAVAILABLE'
    assert local.exists('media/user/scope/blob.bin')


def test_legacy_signed_reader_uses_shared_backend_without_changing_url(tmp_path):
    remote = backend()
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret='unit-signing-secret-32-bytes',
        public_base_url='https://example.invalid', backend=remote)
    storage.put('avatars/u/old.png', b'image')
    token = storage.sign_key('avatars/u/old.png')
    assert storage.read_signed(token, 300) == (b'image', 'image/png')
    assert storage.signed_read_url('avatars/u/old.png', 300).startswith(
        'https://example.invalid/api/v1/profile/avatar/content/')
    assert not (tmp_path / 'avatars/u/old.png').exists()


def test_local_default_and_remote_configuration_validation(tmp_path):
    module = implementation()
    settings = Settings(_env_file=None, environment='test', avatar_storage_root=str(tmp_path))
    assert isinstance(module.build_blob_backend(settings), LocalBlobBackend)
    with pytest.raises(ValueError):
        Settings(_env_file=None, media_blob_backend='s3')
    with pytest.raises(ValueError):
        Settings(_env_file=None, media_blob_backend='s3', media_s3_bucket='unit-bucket',
                 media_s3_region='ap-east-1', media_s3_endpoint='http://example.invalid')


@pytest.mark.parametrize('declared,content', [(5, b'12345'), (2, b'12345'), (2, b'1')])
def test_s3_read_rejects_oversized_or_inconsistent_body_and_closes_stream(declared, content):
    transport = S3Transport()
    stream = BytesIO(content)
    transport.get_object = lambda **_: {'Body': stream, 'ContentLength': declared}
    store = implementation().S3BlobBackend(bucket='unit-bucket', region='ap-east-1',
        client=transport, max_object_bytes=4)
    with pytest.raises(AppError) as caught:
        store.get('media/user/scope/blob.bin')
    assert caught.value.code == 'MEDIA_STORAGE_UNAVAILABLE'
    assert stream.closed


def test_s3_read_rejects_incorrect_full_object_checksum():
    transport = S3Transport()
    transport.get_object = lambda **_: {'Body': BytesIO(b'ab'), 'ContentLength': 2,
        'ChecksumSHA256': base64.b64encode(hashlib.sha256(b'xx').digest()).decode(),
        'ChecksumType': 'FULL_OBJECT'}
    with pytest.raises(AppError):
        backend(transport).get('media/user/scope/blob.bin')


def test_dual_cursor_rejects_oversized_input_and_nonstring_position(tmp_path):
    dual = implementation().DualReadBlobBackend(primary=LocalBlobBackend(root=str(tmp_path)),
        fallback=backend())
    invalid = base64.urlsafe_b64encode(b'{"phase":0,"prefix":"media/","position":{}}').decode()
    for cursor in ('a' * 32769, invalid):
        with pytest.raises(AppError):
            dual.list_page(prefix='media/', cursor=cursor)


@pytest.mark.parametrize('endpoint', ['http://localhost:9000', 'https://localhost/path',
    'https://user:password@localhost', 'https://localhost?token=unsafe', 'https://localhost#fragment'])
def test_config_and_sdk_factory_reject_unsafe_endpoints_without_network(endpoint, monkeypatch):
    import boto3
    calls = []
    monkeypatch.setattr(boto3, 'client', lambda *args, **kwargs: calls.append(kwargs))
    with pytest.raises(ValueError):
        Settings(_env_file=None, environment='test', media_blob_backend='s3',
            media_s3_bucket='unit-bucket', media_s3_region='ap-east-1', media_s3_endpoint=endpoint)
    with pytest.raises(ValueError):
        implementation().S3BlobBackend(bucket='unit-bucket', region='ap-east-1', endpoint=endpoint)
    assert calls == []
