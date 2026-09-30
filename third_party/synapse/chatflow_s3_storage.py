"""Private synchronous local-media S3 provider with permanent deletion fences.

The Synapse database/reference lifecycle remains authoritative. Fences only deny
retired identities, including delayed thumbnail writers outside its worker lock.
They must survive rollback and must never be removed by bucket lifecycle rules.
Installed only in the pinned ChatFlow Synapse derivative (AGPL-3.0).
"""
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit

from synapse.logging.context import defer_to_thread
from synapse.media.media_storage import FileResponder
from synapse.media.storage_provider import StorageProvider


SAFE_COMPONENT = re.compile(r"[A-Za-z0-9_.\[\]:-]+\Z")
MAX_OBJECT_BYTES = 150 * 1024 * 1024


def _component(value):
    if not isinstance(value, str) or not SAFE_COMPONENT.fullmatch(value) or value in (".", ".."):
        raise ValueError("Invalid media storage path component")
    return value


def _not_found(exc):
    # Authentication failures, bucket errors, throttling and outages are NOT misses.
    response = getattr(exc, "response", {})
    return (response.get("ResponseMetadata", {}).get("HTTPStatusCode") == 404
            and response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"))


class ChatFlowS3StorageProvider(StorageProvider):
    def __init__(self, hs, config):
        import boto3
        from botocore.config import Config

        providers = hs.config.media.media_storage_providers
        if len(providers) != 1 or providers[0][0] is not type(self):
            raise ValueError("S3 media requires one lifecycle-aware provider")
        wrapper = providers[0][2]
        if not wrapper.store_local or wrapper.store_remote or not wrapper.store_synchronous:
            raise ValueError("S3 media requires synchronous local-only storage")
        self.hs = hs
        self.reactor = hs.get_reactor()
        self.cache_directory = Path(hs.config.media.media_store_path).resolve()
        self.bucket = config["bucket"]
        self.prefix = config["prefix"] + "/"
        self.max_object_bytes = config["max_object_bytes"]
        self.write_enabled = config["write_enabled"]
        # Credentials use the default SDK chain; never accept/log key material.
        self.client = boto3.client(
            "s3", region_name=config["region"], endpoint_url=config.get("endpoint_url"),
            config=Config(connect_timeout=3, read_timeout=10,
                          retries={"mode": "standard", "total_max_attempts": 3}),
        )

    def __str__(self):
        return "ChatFlowS3StorageProvider"

    @staticmethod
    def parse_config(config):
        if not isinstance(config, dict):
            raise ValueError("Invalid S3 media configuration")
        allowed = {"bucket", "region", "prefix", "max_object_bytes", "endpoint_url", "write_enabled"}
        if set(config) - allowed:
            raise ValueError("Unknown S3 media configuration")
        bucket = config.get("bucket", "")
        region = config.get("region", "")
        prefix = config.get("prefix", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
            raise ValueError("Invalid S3 media bucket")
        if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]", region):
            raise ValueError("Invalid S3 media region")
        if not isinstance(prefix, str) or not prefix or len(prefix) > 512:
            raise ValueError("A private S3 media namespace is required")
        for component in prefix.split("/"):
            _component(component)
        maximum = config.get("max_object_bytes", MAX_OBJECT_BYTES)
        if type(maximum) is not int or not 1 <= maximum <= MAX_OBJECT_BYTES:
            raise ValueError("Invalid S3 media object bound")
        write_enabled = config.get("write_enabled", True)
        if type(write_enabled) is not bool:
            raise ValueError("S3 media write_enabled requires a boolean")
        result = {"bucket": bucket, "region": region, "prefix": prefix,
                  "max_object_bytes": maximum, "write_enabled": write_enabled}
        endpoint = config.get("endpoint_url")
        if endpoint is not None:
            parsed = urlsplit(endpoint)
            if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                    or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
                raise ValueError("S3 endpoint requires verified HTTPS")
            result["endpoint_url"] = endpoint
        return result

    def _path(self, path, file_info):
        parts = path.split("/")
        for part in parts:
            _component(part)
        if ((parts[0] == "local_content" and len(parts) == 4)
                or (parts[0] == "local_thumbnails" and len(parts) == 5)):
            if len(parts[1]) == len(parts[2]) == 2 and "".join(parts[1:4]) == file_info.file_id:
                return self.prefix + path
        raise ValueError("S3 provider accepts only the exact local media path")

    def _fence(self, media_id):
        _component(media_id)
        if len(media_id) < 5 or len(media_id) > 255:
            raise ValueError("Invalid local media identity")
        return self.prefix + "lifecycle_deleted/" + media_id

    def _fenced(self, media_id):
        try:
            self.client.head_object(Bucket=self.bucket, Key=self._fence(media_id))
        except Exception as exc:
            if _not_found(exc):
                return False
            raise RuntimeError("Media storage fence unavailable") from None
        return True

    async def store_file(self, path, file_info):
        # Compatible rollback keeps historical reads and deletion fences active,
        # while ordinary new uploads succeed using the upstream local store.
        if not self.write_enabled or file_info.server_name or file_info.url_cache:
            return
        key = self._path(path, file_info)
        await defer_to_thread(self.reactor, self._store, path, key, file_info.file_id)

    def _store(self, path, key, media_id):
        if self._fenced(media_id):
            raise RuntimeError("Media identity has been retired")
        file = (self.cache_directory / path).resolve()
        if not file.is_relative_to(self.cache_directory):
            raise ValueError("Media cache path escapes storage")
        try:
            with file.open("rb") as source:
                if not 0 <= os.fstat(source.fileno()).st_size <= self.max_object_bytes:
                    raise RuntimeError("Media object exceeds storage bound")
                # A single synchronous PUT avoids background multipart writers
                # escaping the existing publication/compensation worker lock.
                self.client.put_object(Bucket=self.bucket, Key=key, Body=source,
                                       ServerSideEncryption="AES256")
            if self._fenced(media_id):
                self.client.delete_object(Bucket=self.bucket, Key=key)
                raise RuntimeError("Media identity has been retired")
        except Exception:
            # Closed errors prevent SDK response details, keys and paths in logs.
            raise RuntimeError("Media storage write unavailable") from None

    async def fetch(self, path, file_info):
        if file_info.server_name or file_info.url_cache:
            return None
        key = self._path(path, file_info)
        file = await defer_to_thread(self.reactor, self._fetch, key, file_info.file_id)
        return FileResponder(self.hs, file) if file is not None else None

    def _fetch(self, key, media_id):
        if self._fenced(media_id):
            return None
        try:
            result = self.client.get_object(Bucket=self.bucket, Key=key)
        except Exception as exc:
            if _not_found(exc):
                return None
            raise RuntimeError("Media storage read unavailable") from None
        output = None
        try:
            with result["Body"] as body:
                expected = result["ContentLength"]
                if type(expected) is not int or not 0 <= expected <= self.max_object_bytes:
                    raise RuntimeError("Media object exceeds storage bound")
                output = tempfile.TemporaryFile(mode="w+b")
                received = 0
                while True:
                    chunk = body.read(1024 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > expected:
                        raise RuntimeError("Media object length mismatch")
                    output.write(chunk)
                if received != expected:
                    raise RuntimeError("Media object length mismatch")
            if self._fenced(media_id):
                output.close()
                return None
            output.seek(0)
            return output
        except Exception:
            if output is not None:
                output.close()
            raise RuntimeError("Media storage read unavailable") from None

    async def delete_local_media(self, media_id):
        # Called only by the existing authoritative lifecycle while locked.
        fence = self._fence(media_id)
        await defer_to_thread(self.reactor, self._delete, media_id, fence)

    def _delete(self, media_id, fence):
        content = self.prefix + "/".join(("local_content", media_id[:2], media_id[2:4], media_id[4:]))
        thumbnails = self.prefix + "/".join(("local_thumbnails", media_id[:2], media_id[2:4], media_id[4:])) + "/"
        try:
            # Fence first: delayed PUT/read recovery can only deny this identity.
            self.client.put_object(Bucket=self.bucket, Key=fence, Body=b"deleted", ServerSideEncryption="AES256")
            self.client.delete_object(Bucket=self.bucket, Key=content)
            token = None
            seen = set()
            for _ in range(128):
                args = {"Bucket": self.bucket, "Prefix": thumbnails, "MaxKeys": 1000}
                if token:
                    args["ContinuationToken"] = token
                page = self.client.list_objects_v2(**args)
                for item in page.get("Contents", []):
                    key = item["Key"]
                    if not isinstance(key, str) or not key.startswith(thumbnails):
                        raise ValueError("Invalid S3 thumbnail listing")
                    self.client.delete_object(Bucket=self.bucket, Key=key)
                if not page.get("IsTruncated", False):
                    break
                if not page.get("Contents"):
                    raise ValueError("Nonprogressing S3 thumbnail listing")
                token = page.get("NextContinuationToken")
                if not isinstance(token, str) or not token or token in seen:
                    raise ValueError("Invalid S3 thumbnail continuation")
                seen.add(token)
            else:
                raise RuntimeError("Media thumbnail collection requires retry")
        except Exception:
            # Leave the DB pending/retiring record and fence in place for retry.
            raise RuntimeError("Media storage deletion unavailable") from None
