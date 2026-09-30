"""S3 byte lifecycle with synthetic objects; no live credentials or user data."""
import importlib.util
from pathlib import Path
from types import ModuleType, SimpleNamespace
from io import BytesIO
import sys

import boto3 as real_sdk
from botocore.stub import ANY, Stubber
import pytest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "third_party/synapse/chatflow_s3_storage.py"
MEDIA = "abcdefghijklmnopqrstuvwx"
CONTENT = "local_content/ab/cd/efghijklmnopqrstuvwx"
THUMB = "local_thumbnails/ab/cd/efghijklmnopqrstuvwx/32-32-image-png-scale"


class S3Error(Exception):
    def __init__(self, code, status=None):
        if status is None:
            status = 404 if code == "404" else 403
        self.response = {"Error": {"Code": code}, "ResponseMetadata": {"HTTPStatusCode": status}}


class S3:
    def __init__(self):
        self.objects = {}
        self.fail = None
        self.deleted = []
        self.after_put = None

    def head_object(self, **args):
        if self.fail:
            raise S3Error(self.fail)
        if args["Key"] not in self.objects:
            raise S3Error("404")
        return {"ContentLength": len(self.objects[args["Key"]])}

    def put_object(self, **args):
        if self.fail:
            raise S3Error(self.fail)
        assert args["ServerSideEncryption"] == "AES256"
        body = args["Body"]
        self.objects[args["Key"]] = body.read() if hasattr(body, "read") else body
        if self.after_put:
            self.after_put(args["Key"])

    def get_object(self, **args):
        self.head_object(**args)
        data = self.objects[args["Key"]]
        return {"ContentLength": len(data), "Body": BytesIO(data)}

    def delete_object(self, **args):
        if self.fail:
            raise S3Error(self.fail)
        self.deleted.append(args["Key"])
        self.objects.pop(args["Key"], None)

    def list_objects_v2(self, **args):
        if self.fail:
            raise S3Error(self.fail)
        keys = sorted(k for k in self.objects if k.startswith(args["Prefix"]))
        # One object per page deliberately exercises token advancement.
        remaining = [k for k in keys if k > args.get("ContinuationToken", "")]
        page = remaining[:1]
        result = {"Contents": [{"Key": k} for k in page], "IsTruncated": len(remaining) > 1}
        if result["IsTruncated"]:
            result["NextContinuationToken"] = page[-1]
        return result


@pytest.fixture
def provider(tmp_path, monkeypatch):
    async def threaded(reactor, function, *args):
        return function(*args)

    class Responder:
        def __init__(self, hs, file):
            self.file = file

    for name, symbols in {
        "synapse.media.storage_provider": {"StorageProvider": object},
        "synapse.logging.context": {"defer_to_thread": threaded},
        "synapse.media.media_storage": {"FileResponder": Responder},
    }.items():
        stub = ModuleType(name)
        stub.__dict__.update(symbols)
        monkeypatch.setitem(sys.modules, name, stub)
    spec = importlib.util.spec_from_file_location("synapse_s3_test", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    client = S3()
    sdk = ModuleType("boto3")
    sdk.client = lambda *args, **kwargs: client
    monkeypatch.setitem(sys.modules, "boto3", sdk)
    config = module.ChatFlowS3StorageProvider.parse_config({
        "bucket": "synthetic-media-bucket", "region": "ap-southeast-1", "prefix": "synapse",
    })
    wrapper = SimpleNamespace(store_local=True, store_remote=False, store_synchronous=True)
    media = SimpleNamespace(media_store_path=str(tmp_path),
                            media_storage_providers=[(module.ChatFlowS3StorageProvider, config, wrapper)])
    hs = SimpleNamespace(get_reactor=lambda: None, config=SimpleNamespace(media=media))
    backend = module.ChatFlowS3StorageProvider(hs, config)
    return backend, client, tmp_path, module


def info(media_id=MEDIA, remote=None, url=False):
    return SimpleNamespace(file_id=media_id, server_name=remote, url_cache=url)


@pytest.mark.asyncio
async def test_sync_ciphertext_roundtrip_preserves_key_and_local_cache(provider):
    backend, client, root, _ = provider
    file = root / CONTENT
    file.parent.mkdir(parents=True)
    file.write_bytes(b"synthetic ciphertext")
    await backend.store_file(CONTENT, info())
    assert file.read_bytes() == b"synthetic ciphertext"
    assert client.objects["synapse/" + CONTENT] == file.read_bytes()
    response = await backend.fetch(CONTENT, info())
    assert response.file.read() == file.read_bytes()
    response.file.close()


@pytest.mark.asyncio
async def test_delete_fences_exact_object_and_paginated_thumbnails_only(provider):
    backend, client, _, _ = provider
    neighbor = "synapse/local_thumbnails/ab/cd/efghijklmnopqrstuvwx-neighbor/32-32-image-png-scale"
    client.objects.update({"synapse/" + CONTENT: b"cipher", "synapse/" + THUMB: b"thumbnail",
                           "synapse/" + THUMB + "2": b"thumbnail2", neighbor: b"keep"})
    await backend.delete_local_media(MEDIA)
    assert client.objects == {neighbor: b"keep", "synapse/lifecycle_deleted/" + MEDIA: b"deleted"}
    await backend.delete_local_media(MEDIA)  # Retry of a committed/uncertain delete is safe.
    assert await backend.fetch(CONTENT, info()) is None


@pytest.mark.asyncio
async def test_deletion_fence_rejects_delayed_thumbnail_put_and_removes_bytes(provider):
    backend, client, root, _ = provider
    file = root / THUMB
    file.parent.mkdir(parents=True)
    file.write_bytes(b"late thumbnail")
    client.after_put = lambda key: client.objects.update({"synapse/lifecycle_deleted/" + MEDIA: b"deleted"})
    with pytest.raises(RuntimeError):
        await backend.store_file(THUMB, info())
    assert "synapse/" + THUMB not in client.objects


@pytest.mark.asyncio
async def test_fence_is_checked_before_any_put(provider):
    backend, client, root, _ = provider
    client.objects["synapse/lifecycle_deleted/" + MEDIA] = b"deleted"
    with pytest.raises(RuntimeError):
        await backend.store_file(CONTENT, info())
    assert "synapse/" + CONTENT not in client.objects


@pytest.mark.asyncio
async def test_fetch_only_true_not_found_is_a_miss(provider):
    backend, client, _, _ = provider
    assert await backend.fetch(CONTENT, info()) is None
    for error in ("AccessDenied", "SlowDown", "InternalError", "NoSuchBucket"):
        client.fail = error
        with pytest.raises(RuntimeError):
            await backend.fetch(CONTENT, info())


@pytest.mark.asyncio
async def test_list_or_delete_failure_keeps_fence_for_retry(provider):
    backend, client, _, _ = provider
    original = client.list_objects_v2
    client.list_objects_v2 = lambda **kwargs: (_ for _ in ()).throw(S3Error("AccessDenied"))
    client.objects["synapse/" + THUMB] = b"thumbnail"
    with pytest.raises(RuntimeError):
        await backend.delete_local_media(MEDIA)
    assert "synapse/lifecycle_deleted/" + MEDIA in client.objects
    assert await backend.fetch(THUMB, info()) is None
    client.list_objects_v2 = original
    await backend.delete_local_media(MEDIA)
    assert "synapse/" + THUMB not in client.objects


@pytest.mark.parametrize("path", ["../secret", "/local_content/ab/cd/x", CONTENT + "/other",
                                 "local_content/ab/cd/../x", "remote_content/ab/cd/x",
                                 "local_content/ab/cd/not-the-id", "local_content\\ab\\cd\\x"])
@pytest.mark.asyncio
async def test_key_jail_rejects_paths_before_any_s3_access(provider, path):
    backend, client, _, _ = provider
    with pytest.raises(ValueError):
        await backend.fetch(path, info())
    assert client.objects == {}


@pytest.mark.asyncio
async def test_remote_and_url_cache_never_use_bucket(provider):
    backend, client, _, _ = provider
    assert await backend.fetch(CONTENT, info(remote="other.invalid")) is None
    await backend.store_file(CONTENT, info(url=True))
    assert client.objects == {}


@pytest.mark.asyncio
async def test_fetch_size_bound_is_enforced_without_returning_partial_responder(provider):
    backend, client, _, _ = provider
    backend.max_object_bytes = 4
    client.objects["synapse/" + CONTENT] = b"too large"
    with pytest.raises(RuntimeError):
        await backend.fetch(CONTENT, info())


def test_configuration_requires_private_namespace_and_verified_tls(provider):
    _, _, _, module = provider
    for invalid in ({}, {"bucket": "synthetic", "region": "ap-southeast-1", "prefix": ""},
                    {"bucket": "synthetic", "region": "ap-southeast-1", "prefix": "../escape"},
                    {"bucket": "synthetic", "region": "ap-southeast-1", "prefix": "synapse",
                     "endpoint_url": "http://localhost:9000"}):
        with pytest.raises(ValueError):
            module.ChatFlowS3StorageProvider.parse_config(invalid)


def test_async_remote_or_multiple_backup_providers_are_rejected(provider):
    backend, _, _, module = provider
    media = backend.hs.config.media
    klass, config, good = media.media_storage_providers[0]
    for bad in (SimpleNamespace(store_local=True, store_remote=False, store_synchronous=False),
                SimpleNamespace(store_local=True, store_remote=True, store_synchronous=True),
                SimpleNamespace(store_local=False, store_remote=False, store_synchronous=True)):
        media.media_storage_providers = [(klass, config, bad)]
        with pytest.raises(ValueError):
            klass(backend.hs, config)
    media.media_storage_providers = [(klass, config, good), (object, {}, good)]
    with pytest.raises(ValueError):
        klass(backend.hs, config)


@pytest.mark.asyncio
async def test_nonprogressing_thumbnail_pagination_aborts_without_local_delete(provider):
    backend, client, _, _ = provider
    client.list_objects_v2 = lambda **kwargs: {"Contents": [], "IsTruncated": True,
                                               "NextContinuationToken": "never-progress"}
    with pytest.raises(RuntimeError):
        await backend.delete_local_media(MEDIA)
    assert "synapse/lifecycle_deleted/" + MEDIA in client.objects


@pytest.mark.asyncio
async def test_partial_thumbnail_delete_failure_retries_idempotently(provider):
    backend, client, _, _ = provider
    client.objects.update({"synapse/" + CONTENT: b"cipher", "synapse/" + THUMB: b"thumbnail",
                           "synapse/" + THUMB + "2": b"thumbnail2"})
    original = client.delete_object

    def deletion(**kwargs):
        if kwargs["Key"] == "synapse/" + THUMB + "2":
            raise S3Error("AccessDenied")
        return original(**kwargs)

    client.delete_object = deletion
    with pytest.raises(RuntimeError):
        await backend.delete_local_media(MEDIA)
    assert "synapse/" + THUMB + "2" in client.objects
    assert await backend.fetch(THUMB, info()) is None
    client.delete_object = original
    await backend.delete_local_media(MEDIA)
    assert client.objects == {"synapse/lifecycle_deleted/" + MEDIA: b"deleted"}


@pytest.mark.asyncio
async def test_fetch_checks_retirement_after_downloading_snapshot(provider):
    backend, client, _, _ = provider
    client.objects["synapse/" + CONTENT] = b"ciphertext"
    original = client.get_object

    def downloading(**kwargs):
        result = original(**kwargs)
        client.objects["synapse/lifecycle_deleted/" + MEDIA] = b"deleted"
        return result

    client.get_object = downloading
    assert await backend.fetch(CONTENT, info()) is None


@pytest.mark.asyncio
async def test_thumbnail_collection_is_bounded_even_with_unique_broken_tokens(provider):
    backend, client, _, _ = provider
    calls = []

    def listing(**kwargs):
        calls.append(kwargs)
        if len(calls) > 128:
            raise AssertionError("unbounded list loop")
        return {"Contents": [{"Key": "synapse/" + THUMB}], "IsTruncated": True,
                "NextContinuationToken": str(len(calls))}

    client.list_objects_v2 = listing
    with pytest.raises(RuntimeError):
        await backend.delete_local_media(MEDIA)
    assert len(calls) <= 128


@pytest.mark.parametrize("code", ["NoSuchKey", "NotFound", "404"])
@pytest.mark.parametrize("status", [403, 503, None])
@pytest.mark.asyncio
async def test_missing_object_code_with_wrong_or_missing_http_status_is_not_a_miss(provider, code, status):
    backend, client, _, _ = provider

    def error(**kwargs):
        exc = S3Error(code, status)
        if status is None:
            exc.response.pop("ResponseMetadata")
        raise exc

    client.head_object = error
    with pytest.raises(RuntimeError):
        await backend.fetch(CONTENT, info())


@pytest.mark.asyncio
async def test_real_sdk_request_models_and_not_found_responses_without_network(provider, monkeypatch):
    backend, _, root, _ = provider
    monkeypatch.setitem(sys.modules, "boto3", real_sdk)
    client = real_sdk.client("s3", region_name="ap-southeast-1",
                             aws_access_key_id="synthetic", aws_secret_access_key="synthetic")
    backend.client = client
    file = root / CONTENT
    file.parent.mkdir(parents=True)
    file.write_bytes(b"synthetic ciphertext")
    bucket = backend.bucket
    fence = {"Bucket": bucket, "Key": "synapse/lifecycle_deleted/" + MEDIA}
    object_args = {"Bucket": bucket, "Key": "synapse/" + CONTENT}
    with Stubber(client) as stub:
        stub.add_client_error("head_object", "404", http_status_code=404, expected_params=fence)
        stub.add_response("put_object", {"ETag": '"synthetic"'},
                          {**object_args, "Body": ANY, "ServerSideEncryption": "AES256"})
        stub.add_client_error("head_object", "404", http_status_code=404, expected_params=fence)
        await backend.store_file(CONTENT, info())
        stub.add_client_error("head_object", "404", http_status_code=404, expected_params=fence)
        stub.add_response("get_object", {"Body": BytesIO(file.read_bytes()), "ContentLength": file.stat().st_size}, object_args)
        stub.add_client_error("head_object", "404", http_status_code=404, expected_params=fence)
        response = await backend.fetch(CONTENT, info())
        assert response.file.read() == file.read_bytes()
        response.file.close()
        stub.add_response("put_object", {}, {**fence, "Body": b"deleted", "ServerSideEncryption": "AES256"})
        stub.add_response("delete_object", {}, object_args)
        stub.add_response("list_objects_v2", {"IsTruncated": False, "Contents": []},
                          {"Bucket": bucket, "Prefix": "synapse/local_thumbnails/ab/cd/efghijklmnopqrstuvwx/", "MaxKeys": 1000})
        await backend.delete_local_media(MEDIA)
        stub.assert_no_pending_responses()


@pytest.mark.asyncio
async def test_local_write_rollback_preserves_remote_reads_fences_and_gc(provider):
    backend, client, root, module = provider
    _, config, wrapper = backend.hs.config.media.media_storage_providers[0]
    read_only_config = module.ChatFlowS3StorageProvider.parse_config({**config, "write_enabled": False})
    rollback = module.ChatFlowS3StorageProvider(backend.hs, read_only_config)
    client.objects["synapse/" + CONTENT] = b"historical ciphertext"
    # Local writes must work during a remote outage without any S3 call.
    client.fail = "AccessDenied"
    await rollback.store_file(CONTENT, info())
    client.fail = None
    assert client.objects["synapse/" + CONTENT] == b"historical ciphertext"
    response = await rollback.fetch(CONTENT, info())
    assert response.file.read() == b"historical ciphertext"
    response.file.close()
    await rollback.delete_local_media(MEDIA)
    assert "synapse/" + CONTENT not in client.objects
    assert "synapse/lifecycle_deleted/" + MEDIA in client.objects
    assert await rollback.fetch(CONTENT, info()) is None


@pytest.mark.parametrize("invalid", [0, 1, "false", "true", None, [], {}])
def test_write_enabled_accepts_only_booleans(provider, invalid):
    backend, _, _, module = provider
    _, config, _ = backend.hs.config.media.media_storage_providers[0]
    with pytest.raises(ValueError):
        module.ChatFlowS3StorageProvider.parse_config({**config, "write_enabled": invalid})


def test_new_upload_writes_remain_enabled_by_default(provider):
    backend, _, _, _ = provider
    assert backend.write_enabled is True
