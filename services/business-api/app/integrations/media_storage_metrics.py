"""Fixed, process-local storage observations: ten series and at most 2,560 samples.

Counters cover process lifetime; latency percentiles cover each series' last 256
logical operations, including SDK retries within their duration. These are not
billable-request counters. No object identifier, bucket, region, exception text
or content is kept.
"""
from collections import deque
from functools import wraps
from math import ceil, isfinite
from threading import Lock
from time import perf_counter

from botocore.exceptions import (ClientError, ConnectTimeoutError, EndpointConnectionError,
    NoCredentialsError, PartialCredentialsError, ReadTimeoutError)

from app.core.errors import AppError

BACKENDS = ('s3', 'dual')
OPERATIONS = ('put', 'get', 'exists', 'delete', 'list')
OUTCOMES = ('success', 'missing', 'denied', 'upstream', 'throttled', 'timeout',
            'transport', 'credentials', 'invalid', 'unavailable', 'error')


def classify_storage_error(error) -> str:
    category = getattr(error, '_storage_metrics_outcome', None)
    if category in OUTCOMES:
        return category
    if isinstance(error, ClientError):
        response = error.response
        status = response.get('ResponseMetadata', {}).get('HTTPStatusCode')
        code = response.get('Error', {}).get('Code')
        if status == 403:
            return 'denied'
        if status == 408 or code in ('RequestTimeout', 'RequestTimeoutException'):
            return 'timeout'
        if status == 429 or code in ('SlowDown', 'Throttling', 'ThrottlingException'):
            return 'throttled'
        if isinstance(status, int) and status >= 500:
            return 'upstream'
        return 'unavailable'
    if isinstance(error, (NoCredentialsError, PartialCredentialsError)):
        return 'credentials'
    if isinstance(error, (ConnectTimeoutError, ReadTimeoutError, TimeoutError)):
        return 'timeout'
    if isinstance(error, (EndpointConnectionError, OSError)):
        return 'transport'
    if isinstance(error, AppError):
        return {'MEDIA_BLOB_MISSING': 'missing', 'MEDIA_STORAGE_KEY_INVALID': 'invalid',
                'MEDIA_STORAGE_UNAVAILABLE': 'unavailable'}.get(error.code, 'error')
    if isinstance(error, (ValueError, TypeError)):
        return 'invalid'
    return 'error'


class StorageBackendMetrics:
    def __init__(self):
        self._lock = Lock()
        self.reset()

    def reset(self):
        with self._lock:
            self._counters = {f'storage_{backend}_{operation}_{outcome}': 0
                for backend in BACKENDS for operation in OPERATIONS
                for outcome in (*OUTCOMES, 'total', 'fallback')}
            self._samples = {(backend, operation): deque(maxlen=256)
                for backend in BACKENDS for operation in OPERATIONS}

    def record(self, backend, operation, outcome, duration_ms):
        if backend not in BACKENDS or operation not in OPERATIONS or outcome not in OUTCOMES:
            raise ValueError('storage metric label invalid')
        if not isfinite(duration_ms):
            raise ValueError('storage metric duration invalid')
        with self._lock:
            self._counters[f'storage_{backend}_{operation}_total'] += 1
            self._counters[f'storage_{backend}_{operation}_{outcome}'] += 1
            self._samples[backend, operation].append(max(0.0, float(duration_ms)))

    def fallback(self, operation):
        if operation not in OPERATIONS:
            raise ValueError('storage metric label invalid')
        with self._lock:
            self._counters[f'storage_dual_{operation}_fallback'] += 1

    def snapshot(self):
        with self._lock:
            counters = dict(self._counters)
            windows = {key: tuple(values) for key, values in self._samples.items()}
        timings = {}
        for (backend, operation), values in windows.items():
            ordered = sorted(values)
            count = len(ordered)
            timings[f'storage_{backend}_{operation}_ms'] = {
                'count': count, 'avg_ms': round(sum(ordered) / count, 3) if count else 0.0,
                'max_ms': round(ordered[-1], 3) if count else 0.0,
                **{f'p{int(percent * 100)}_ms': round(ordered[ceil(count * percent) - 1], 3)
                   if count else None for percent in (0.50, 0.95, 0.99)}}
        return {'counters': counters, 'timings': timings}


storage_backend_metrics = StorageBackendMetrics()


def observe_storage(backend, operation):
    if backend not in BACKENDS or operation not in OPERATIONS:
        raise ValueError('storage metric label invalid')
    def decorate(function):
        @wraps(function)
        def measured(*args, **kwargs):
            started = perf_counter()
            outcome = 'success'
            try:
                result = function(*args, **kwargs)
                if operation == 'exists' and result is False:
                    outcome = 'missing'
                return result
            except Exception as error:
                outcome = classify_storage_error(error)
                raise
            finally:
                storage_backend_metrics.record(backend, operation, outcome,
                    (perf_counter() - started) * 1000.0)
        return measured
    return decorate
