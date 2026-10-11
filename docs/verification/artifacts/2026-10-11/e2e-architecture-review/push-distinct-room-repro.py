"""Offline-only reproduction. Run with PYTHONPATH=services/getui-bridge.

Every HTTP request uses MockTransport or ASGI TestClient; no real push is sent.
"""
import json
from types import SimpleNamespace

import httpx
from fastapi.testclient import TestClient

from app.config import BridgeSettings
from app.main import create_app
import app.rate_limit as rate_limit

clock = [100.0]
rate_limit.time = SimpleNamespace(monotonic=lambda: clock[0])
sent = []


def provider(request):
    if request.url.path.endswith('/auth'):
        return httpx.Response(200, json={'code': 0, 'data': {
            'token': 'fixture', 'expire_time': 9999999999999}})
    sent.append(json.loads(request.content))
    return httpx.Response(200, json={'code': 0, 'data': {
        'status': 'successed_online'}})


app = create_app(BridgeSettings(
    getui_app_id='fixture', getui_app_key='fixture', getui_sign_secret='fixture',
    rate_limit_ms=1500),
    http_client=httpx.Client(transport=httpx.MockTransport(provider)))
client = TestClient(app)


def message(room, event):
    return {'notification': {'room_id': room, 'event_id': event, 'devices': [{
        'app_id': 'com.liuhetong.mobile.getui', 'pushkey': 'fixture',
        'data': {'chatflow_push_v': 1, 'chatflow_push_scope': 'a' * 64,
                 'chatflow_push_revision': 1}}]}}


a = client.post('/_matrix/push/v1/notify', json=message('!roomA:test', '$eventA'))
clock[0] = 100.1
b = client.post('/_matrix/push/v1/notify', json=message('!roomB:test', '$eventB'))
assert a.status_code == 200 and b.status_code == 200 and len(sent) == 1
print('DISTINCT_ROOM_SILENT_DROP_CONFIRMED http_statuses=200,200 provider_requests=1 expected_distinct_events=2')
print('V1_VENDOR_FALLBACK_PRESENT', 'push_channel' in sent[0])
