"""Closed request facts and a bounded, nonblocking, identity-free log sink."""
from datetime import datetime
import json
from queue import Empty, Full, Queue
import re
import sys
from threading import Event, Lock, Thread
from time import monotonic
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator

REQUEST_ID_PATTERN = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
UTC_PATTERN = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$'
METHODS = ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS', 'OTHER')
ENDPOINT_CATEGORIES = ('auth', 'profile', 'contacts', 'media', 'finance', 'settings', 'support', 'other')
Methods = Literal['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS', 'OTHER']
EndpointCategories = Literal['auth', 'profile', 'contacts', 'media', 'finance', 'settings', 'support', 'other']
Milliseconds = Annotated[int, Field(ge=0, le=3600000)]
UtcTime = Annotated[str, Field(max_length=32, pattern=UTC_PATTERN)]


def valid_request_id(value: str | None) -> str | None:
    return value if isinstance(value, str) and re.fullmatch(REQUEST_ID_PATTERN, value) else None


def endpoint_category_for_route(template: str) -> str:
    # Read only the registered static template, never a request URL or value.
    segment = template.split('/')[3] if template.startswith('/api/v1/') else ''
    return ({'auth': 'auth', 'phone': 'auth', 'email': 'auth', 'invitations': 'auth', 'profile': 'profile', 'users': 'profile',
             'contacts': 'contacts', 'contact-tags': 'contacts', 'blocks': 'contacts',
             'friends': 'contacts', 'friendships': 'contacts', 'groups': 'contacts',
             'media': 'media', 'uploads': 'media', 'moments': 'media',
             'wallet': 'finance', 'ledger': 'finance', 'caibi': 'finance', 'fx': 'finance',
             'red-packets': 'finance', 'transfers': 'finance', 'recharges': 'finance',
             'payouts': 'finance', 'withdrawals': 'finance', 'settings': 'settings',
             'app-update': 'settings', 'push': 'settings', 'presence': 'settings',
             'support': 'support', 'complaints': 'support'}.get(segment, 'other'))


class NetworkRequestDiagnostic(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    request_id: str = Field(pattern=REQUEST_ID_PATTERN)
    version: str = Field(max_length=32, pattern=r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$')
    platform: Literal['android', 'ios', 'other']
    target: Literal['primary_api']
    network: Literal['unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other']
    method: Methods
    endpoint_category: EndpointCategories
    started_at: UtcTime
    elapsed_ms: Milliseconds
    phase: Literal['awaiting_headers', 'reading_body', 'response_complete', 'unknown']
    reason: Literal['timeout', 'socket', 'tls', 'http_transport', 'aborted', 'unexpected', 'http_5xx']
    operation_id: str | None = Field(default=None, pattern=REQUEST_ID_PATTERN)
    headers_ms: Milliseconds | None = None
    http_status: int | None = Field(default=None, ge=100, le=599)
    timeout_budget_ms: int | None = Field(default=None, ge=1, le=3600000)
    timeout_lateness_ms: Milliseconds | None = None

    @model_validator(mode='after')
    def valid_boundaries(self):
        datetime.fromisoformat(self.started_at.replace('Z', '+00:00'))
        if self.headers_ms is not None and self.headers_ms > self.elapsed_ms:
            raise ValueError('Unordered request timings')
        if self.phase == 'awaiting_headers' and (self.headers_ms is not None or self.http_status is not None):
            raise ValueError('Response facts precede observed headers')
        if self.phase in ('reading_body', 'response_complete') and (self.headers_ms is None or self.http_status is None):
            raise ValueError('Observed response phase requires response headers')
        if self.reason != 'timeout' and (self.timeout_budget_ms is not None or self.timeout_lateness_ms is not None):
            raise ValueError('Timeout metadata requires timeout')
        if self.reason == 'http_5xx' and (self.http_status is None or self.http_status < 500):
            raise ValueError('Server error requires an observed 5xx')
        return self


class NetworkRequestTimeline(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    event: Literal['server_request_timeline']
    request_id: str = Field(pattern=REQUEST_ID_PATTERN)
    server_started_at: UtcTime
    elapsed_ms: Milliseconds
    method: Methods
    endpoint_category: EndpointCategories
    route_template: str = Field(max_length=256, pattern=r'^(<unmatched>|/[A-Za-z0-9_/{}.-]*)$')
    termination: Literal['complete', 'cancelled', 'exception']
    http_status: int | None = Field(default=None, ge=100, le=599)
    headers_prepared_ms: Milliseconds | None = None
    body_prepared_ms: Milliseconds | None = None
    send_finished_ms: Milliseconds | None = None

    @model_validator(mode='after')
    def valid_boundaries(self):
        datetime.fromisoformat(self.server_started_at.replace('Z', '+00:00'))
        previous = -1
        for timing in (self.headers_prepared_ms, self.body_prepared_ms, self.send_finished_ms):
            if timing is not None:
                if timing < previous or timing > self.elapsed_ms:
                    raise ValueError('Unordered server timings')
                previous = timing
        if (self.http_status is None) != (self.headers_prepared_ms is None):
            raise ValueError('Status requires prepared response headers')
        if self.body_prepared_ms is not None and self.headers_prepared_ms is None:
            raise ValueError('Body requires prepared response headers')
        if self.termination == 'complete':
            if self.send_finished_ms is None or self.body_prepared_ms is None or self.send_finished_ms != self.elapsed_ms:
                raise ValueError('Complete response requires final ASGI send')
        elif self.send_finished_ms is not None:
            raise ValueError('Incomplete response cannot confirm final ASGI send')
        return self


class NetworkRequestTimelineDrops(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    event: Literal['server_request_timeline_dropped']
    cumulative: Literal[True]
    queue_full: int = Field(ge=0)
    rate_limited: int = Field(ge=0)
    closed: int = Field(ge=0)
    sink_error: int = Field(ge=0)

    @field_validator('cumulative', mode='before')
    @classmethod
    def exact_true(cls, value):
        if value is not True:
            raise ValueError('Cumulative marker must be boolean true')
        return value


def _stdout_writer(line: str) -> None:
    # Executed only on the dedicated consumer, never on the ASGI request task.
    sys.stdout.write(line + '\n')
    sys.stdout.flush()


class NetworkRequestTimelineSink:
    """Per-process cap and queue; no audit context or request objects retained.

    Closing joins for a finite budget. A blocked stdout cannot be forcibly
    interrupted by Python; the daemon consumer cannot keep the process alive.
    """

    def __init__(self, *, capacity=1024, rate_limit=600, writer=None, clock=monotonic, start=True):
        if capacity < 1 or rate_limit < 1:
            raise ValueError('Positive timeline limits required')
        self._queue = Queue(maxsize=capacity)
        self._rate_limit, self._writer, self._clock = rate_limit, writer or _stdout_writer, clock
        self._lock, self._stop = Lock(), Event()
        self._closed = False
        self._window_start, self._window_count = clock(), 0
        self._drops = dict.fromkeys(('queue_full', 'rate_limited', 'closed', 'sink_error'), 0)
        self.thread = Thread(target=self._consume, name='chatflow-request-timeline', daemon=True)
        if start:
            self.thread.start()

    def submit(self, record: dict) -> bool:
        try:
            # Reconstruct an immutable closed record; never retain caller maps.
            safe = NetworkRequestTimeline.model_validate(record).model_dump(exclude_none=True)
        except (ValidationError, TypeError, ValueError):
            return False
        with self._lock:
            if self._closed:
                self._drops['closed'] += 1
                return False
            now = self._clock()
            if now - self._window_start >= 60:
                self._window_start, self._window_count = now, 0
            if self._window_count >= self._rate_limit:
                self._drops['rate_limited'] += 1
                return False
            self._window_count += 1
            try:
                self._queue.put_nowait(safe)
            except Full:
                self._drops['queue_full'] += 1
                return False
            if self.thread.ident is None:
                self.thread.start()
        return True

    def snapshot(self) -> dict:
        with self._lock:
            return dict(self._drops)

    def _write(self, value: dict) -> None:
        try:
            self._writer(json.dumps(value, ensure_ascii=True, separators=(',', ':'), allow_nan=False))
        except Exception:
            # Logging failures must never print original record/traceback.
            with self._lock:
                self._drops['sink_error'] += 1

    def _consume(self) -> None:
        last_drops = dict.fromkeys(self._drops, 0)
        last_report = self._clock() - 60
        while not self._stop.is_set() or not self._queue.empty():
            try:
                row = self._queue.get(timeout=.05)
            except Empty:
                row = None
            if row is not None:
                self._write(row)
                self._queue.task_done()
            drops = self.snapshot()
            now = self._clock()
            if drops != last_drops and (now - last_report >= 60 or self._stop.is_set()):
                self._write({'event': 'server_request_timeline_dropped', 'cumulative': True, **drops})
                last_drops, last_report = drops, now

    def close(self, *, timeout=.25) -> None:
        with self._lock:
            self._closed = True
        self._stop.set()
        if self.thread.ident is not None:
            self.thread.join(timeout=max(0, timeout))
