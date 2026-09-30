import importlib
import importlib.util
import json
from concurrent.futures import ThreadPoolExecutor

import pytest

from app.core.errors import AppError
from app.modules.media.metrics import MediaPlatformMetrics
from app.modules.media.storage import LocalBlobBackend
from test_s3_storage import S3Transport, backend, client_error, implementation


def metrics_module():
    name = 'app.integrations.media_storage_metrics'
    assert importlib.util.find_spec(name) is not None, 'bounded storage metrics are missing'
    return importlib.import_module(name)


def capacity_module():
    name = 'app.integrations.media_storage_capacity'
    assert importlib.util.find_spec(name) is not None, 'bounded capacity collector is missing'
    return importlib.import_module(name)


def test_sdk_operations_record_latency_outcomes_without_private_labels():
    metrics = metrics_module().storage_backend_metrics
    metrics.reset()
    transport = S3Transport()
    store = backend(transport)
    key = 'avatars/unit-user/PRIVATE_OBJECT.png'
    store.put(key, b'PRIVATE_CONTENT')
    assert store.get(key) == b'PRIVATE_CONTENT'
    assert not store.exists('avatars/unit-user/missing.png')
    store.delete(key)
    store.list_page(prefix='avatars/')
    with pytest.raises(AppError):
        store.get(key)
    transport.failure = client_error('PRIVATE_PROVIDER_ERROR', 403)
    with pytest.raises(AppError):
        store.get(key)
    snapshot = MediaPlatformMetrics().snapshot()
    assert snapshot['counters']['storage_s3_get_total'] == 3
    assert snapshot['counters']['storage_s3_get_success'] == 1
    assert snapshot['counters']['storage_s3_get_missing'] == 1
    assert snapshot['counters']['storage_s3_get_denied'] == 1
    assert snapshot['timings']['storage_s3_get_ms']['count'] == 3
    assert snapshot['timings']['storage_s3_get_ms']['p95_ms'] is not None
    assert set(snapshot) == {'counters', 'timings'}
    serialized = json.dumps(snapshot)
    assert 'PRIVATE_' not in serialized and 'unit-user' not in serialized
    assert 'unit-bucket' not in serialized and 'business/' not in serialized


def test_dual_fallback_and_errors_keep_separate_s3_and_request_counts(tmp_path):
    metrics = metrics_module().storage_backend_metrics
    metrics.reset()
    transport = S3Transport()
    remote = backend(transport)
    local = LocalBlobBackend(root=str(tmp_path))
    key = 'avatars/unit-user/fallback.png'
    local.put(key, b'old')
    dual = implementation().DualReadBlobBackend(primary=remote, fallback=local)
    assert dual.get(key) == b'old'
    transport.failure = client_error('AccessDenied', 403)
    with pytest.raises(AppError):
        dual.get(key)
    counters = metrics.snapshot()['counters']
    assert counters['storage_dual_get_total'] == 2
    assert counters['storage_dual_get_fallback'] == 1
    assert counters['storage_dual_get_success'] == 1
    assert counters['storage_dual_get_denied'] == 1
    assert counters['storage_s3_get_missing'] == 1


def test_metric_memory_and_counts_are_bounded_and_thread_safe():
    metrics = metrics_module().StorageBackendMetrics()
    def record_many(_):
        for _ in range(1000):
            metrics.record('s3', 'get', 'success', 1.25)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(record_many, range(8)))
    snapshot = metrics.snapshot()
    assert snapshot['counters']['storage_s3_get_total'] == 8000
    assert snapshot['timings']['storage_s3_get_ms']['count'] == 256
    assert snapshot['timings']['storage_s3_get_ms']['p95_ms'] == 1.25
    assert sum(value['count'] for value in snapshot['timings'].values()) <= 2560
    for backend_name, operation, outcome in (
            ('PRIVATE_BUCKET', 'get', 'success'), ('s3', 'PRIVATE_KEY', 'success'),
            ('s3', 'get', 'PRIVATE_ERROR')):
        with pytest.raises(ValueError):
            metrics.record(backend_name, operation, outcome, 1)
    assert 'PRIVATE_' not in json.dumps(metrics.snapshot())


@pytest.mark.parametrize('code,status', [('RequestTimeout', 400), ('RequestTimeoutException', 400),
                                         ('PRIVATE_PROVIDER_ERROR', 408)])
def test_provider_reported_timeouts_use_closed_timeout_metric(code, status):
    metrics = metrics_module().storage_backend_metrics
    metrics.reset()
    transport = S3Transport()
    transport.failure = client_error(code, status)
    with pytest.raises(AppError) as caught:
        backend(transport).get('avatars/unit-user/PRIVATE_OBJECT.png')
    assert caught.value.code == 'MEDIA_STORAGE_UNAVAILABLE'
    assert metrics.snapshot()['counters']['storage_s3_get_timeout'] == 1
    assert metrics.snapshot()['counters']['storage_s3_get_unavailable'] == 0


class CapacityTransport:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []
    def list_objects_v2(self, **kwargs):
        self.calls.append(kwargs)
        value = self.responses[(kwargs['Prefix'], kwargs.get('ContinuationToken'))]
        if isinstance(value, Exception):
            raise value
        return value


def test_capacity_counts_media_fences_separately_and_never_exposes_keys():
    client = CapacityTransport({
        ('business/', None): {'Contents': [{'Key': 'business/avatars/PRIVATE_OBJECT', 'Size': 10}],
            'IsTruncated': True, 'NextContinuationToken': 'PRIVATE_CURSOR'},
        ('business/', 'PRIVATE_CURSOR'): {'Contents': [], 'IsTruncated': False},
        ('synapse/', None): {'Contents': [
            {'Key': 'synapse/local_content/PRIVATE_OBJECT', 'Size': 20},
            {'Key': 'synapse/lifecycle_deleted/PRIVATE_OBJECT', 'Size': 7}], 'IsTruncated': False},
    })
    report = capacity_module().collect_storage_capacity(client=client, bucket='unit-bucket', max_pages=5)
    assert report['coverage'] == 'COMPLETE_BOUNDED_LISTING' and report['non_atomic'] is True
    assert report['listing_scope'] == 'current_objects_only'
    assert report['noncurrent_versions_included'] is False
    assert report['multipart_uploads_included'] is False
    assert report['domains']['business']['media_object_count'] == 1
    assert report['domains']['business']['media_bytes'] == 10
    assert report['domains']['synapse']['media_object_count'] == 1
    assert report['domains']['synapse']['media_bytes'] == 20
    assert report['domains']['synapse']['fence_object_count'] == 1
    assert report['domains']['synapse']['fence_bytes'] == 7
    assert report['object_count'] == 3 and report['bytes'] == 37
    assert report['pages'] == 3
    assert 'PRIVATE_' not in json.dumps(report) and 'unit-bucket' not in json.dumps(report)
    assert all(call['MaxKeys'] <= 1000 for call in client.calls)


def test_capacity_page_budget_never_claims_empty_unscanned_domain_complete():
    client = CapacityTransport({('business/', None): {'Contents': [], 'IsTruncated': False}})
    report = capacity_module().collect_storage_capacity(client=client, bucket='unit-bucket', max_pages=1)
    assert report['coverage'] == 'INCOMPLETE'
    assert report['domains']['business']['coverage'] == 'COMPLETE_BOUNDED_LISTING'
    assert report['domains']['synapse']['coverage'] == 'INCOMPLETE'
    assert report['object_count'] == 0 and report['pages'] == 1


@pytest.mark.parametrize('response', [client_error('PRIVATE_FAILURE', 403),
    {'Contents': [{'Key': 'elsewhere/PRIVATE_OBJECT', 'Size': 1}], 'IsTruncated': False},
    {'Contents': [{'Key': 'business/PRIVATE_OBJECT', 'Size': -1}], 'IsTruncated': False},
    {'Contents': [], 'IsTruncated': True, 'NextContinuationToken': ''}])
def test_capacity_error_is_explicit_and_not_false_complete(response):
    client = CapacityTransport({('business/', None): response,
        ('synapse/', None): {'Contents': [], 'IsTruncated': False}})
    report = capacity_module().collect_storage_capacity(client=client, bucket='unit-bucket', max_pages=5)
    assert report['coverage'] == 'ERROR'
    assert report['domains']['business']['coverage'] == 'ERROR'
    assert report['domains']['business']['error'] in ('denied', 'invalid')
    assert 'PRIVATE_' not in json.dumps(report)


def test_capacity_repeated_cursor_reports_error_without_unbounded_requests():
    page = {'Contents': [], 'IsTruncated': True, 'NextContinuationToken': 'PRIVATE_CURSOR'}
    client = CapacityTransport({('business/', None): page, ('business/', 'PRIVATE_CURSOR'): page,
        ('synapse/', None): {'Contents': [], 'IsTruncated': False}})
    report = capacity_module().collect_storage_capacity(client=client, bucket='unit-bucket', max_pages=100)
    assert report['coverage'] == 'ERROR' and len(client.calls) == 3


def test_capacity_partial_error_keeps_only_prior_validated_totals():
    client = CapacityTransport({
        ('business/', None): {'Contents': [{'Key': 'business/avatars/PRIVATE_OBJECT', 'Size': 10}],
            'IsTruncated': True, 'NextContinuationToken': 'PRIVATE_CURSOR'},
        ('business/', 'PRIVATE_CURSOR'): client_error('PRIVATE_FAILURE', 403),
        ('synapse/', None): {'Contents': [], 'IsTruncated': False}})
    report = capacity_module().collect_storage_capacity(client=client, bucket='unit-bucket')
    assert report['coverage'] == 'ERROR'
    assert report['object_count'] == 1 and report['bytes'] == 10
    assert report['domains']['business']['coverage'] == 'ERROR'
    assert report['domains']['synapse']['coverage'] == 'COMPLETE_BOUNDED_LISTING'
    assert 'PRIVATE_' not in json.dumps(report)


def test_capacity_time_budget_marks_both_unscanned_prefixes_incomplete(monkeypatch):
    module = capacity_module()
    times = iter([0, 2, 2, 2])
    monkeypatch.setattr(module, 'monotonic', lambda: next(times))
    client = CapacityTransport({})
    report = module.collect_storage_capacity(client=client, bucket='unit-bucket', max_seconds=1)
    assert report['coverage'] == 'INCOMPLETE'
    assert report['pages'] == 0 and client.calls == []
    assert all(domain['coverage'] == 'INCOMPLETE' for domain in report['domains'].values())
