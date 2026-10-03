import hashlib
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import BridgeSettings
from app.main import create_app


def send(devices, **fields):
    sent = []

    def transport(request):
        if request.url.path.endswith('/auth'):
            return httpx.Response(200, json={'code': 0, 'data': {'token': 'test', 'expire_time': '9999999999999'}})
        sent.append(json.loads(request.content))
        return httpx.Response(200, json={'code': 0})

    app = create_app(BridgeSettings(getui_app_id='test', getui_app_key='test', getui_sign_secret='test', rate_limit_ms=0),
                     http_client=httpx.Client(transport=httpx.MockTransport(transport)))
    response = TestClient(app).post('/_matrix/push/v1/notify', content=json.dumps({'notification': {
        'type': 'm.room.encrypted', 'room_id': '!测试:r', 'event_id': '$event',
        'content': {'body': 'DO NOT FORWARD'}, 'devices': devices, **fields,
    }}), headers={'content-type': 'application/json'})
    return response, sent


def device(scope='a' * 64, cid='one', version=1):
    return {'app_id': 'com.liuhetong.mobile.getui', 'pushkey': cid,
            'data': {'chatflow_push_v': version, 'chatflow_push_scope': scope,
                     'chatflow_push_revision': 1, 'secret': 'DO NOT FORWARD'}}


def test_v1_is_scoped_transmission_without_os_vendor_bypass():
    response, sent = send([device()])
    assert response.status_code == 200
    assert len(sent) == 1
    assert 'push_channel' not in sent[0]
    payload = json.loads(sent[0]['push_message']['transmission'])
    key = lambda value: hashlib.sha256(('a' * 64 + '\0' + value).encode()).hexdigest()
    assert payload == {'type': 'message', 'v': 1, 'scope': 'a' * 64,
                       'room_key': key('!测试:r'), 'event_key': key('$event')}
    assert 'DO NOT FORWARD' not in json.dumps(sent)


@pytest.mark.parametrize('version,scope', [(True, 'a' * 64), (2, 'a' * 64), (1, 'bad'), (1, 'A' * 64)])
def test_invalid_opt_in_does_not_downgrade_or_reject_cid(version, scope):
    response, sent = send([device(version=version, scope=scope)])
    assert response.status_code == 200
    assert response.json().get('rejected', []) == []
    assert sent == []


def test_per_device_scope_and_legacy_call_compatibility():
    legacy = {'app_id': 'com.liuhetong.mobile.getui', 'pushkey': 'old'}
    _, sent = send([device(), device('b' * 64, 'two'), legacy])
    by_cid = {body['audience']['cid'][0]: body for body in sent}
    assert json.loads(by_cid['two']['push_message']['transmission'])['scope'] == 'b' * 64
    assert 'push_channel' in by_cid['old']
    _, calls = send([device()], type='m.call.invite')
    assert json.loads(calls[0]['push_message']['transmission']) == {'type': 'call'}
    assert 'push_channel' in calls[0]


def test_conflicting_cid_and_oversized_identifier_are_ineligible():
    assert send([device(), device('b' * 64)])[1] == []
    assert send([device()], room_id='x' * 1025)[1] == []


def test_gateway_caps_input_before_fanout():
    response, sent = send([device(cid=str(i)) for i in range(101)])
    assert response.status_code == 400
    assert sent == []


def test_lone_surrogate_identifier_is_rejected_without_provider_delivery():
    response, sent = send([device()], room_id='\ud800')
    assert response.status_code == 400
    assert sent == []
