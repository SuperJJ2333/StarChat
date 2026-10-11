"""Pinned Sygnal 0.15.1; run with --network none and synthetic Flutter data.

Real dispatch, payload truncation and APNs request construction; only the final
APNs transport is replaced. No token/certificate/production config is loaded.
"""
import asyncio
import copy
import json
import logging
from pathlib import Path
import sys
from types import SimpleNamespace

import opentracing
from sygnal.apnspushkin import ApnsPushkin
from sygnal.notifications import Notification


async def run():
    logging.disable(logging.CRITICAL)
    fixtures = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    original = copy.deepcopy(fixtures)
    pushkin = object.__new__(ApnsPushkin)
    pushkin.name = 'synthetic'
    pushkin.sygnal = SimpleNamespace(tracer=opentracing.Tracer())
    pushkin.push_type = 'alert'
    pushkin.get_config = lambda *args: False  # already-hex synthetic token
    sent = []

    async def capture(request):
        sent.append(copy.deepcopy(request.message))
        return SimpleNamespace(status=200, is_successful=True)

    pushkin._send_notification = capture
    for mode in ('silent', 'audible'):
        notification = Notification({'event_id': '$synthetic', 'room_id': '!synthetic:test',
            'counts': {'unread': 2}, 'devices': [{'app_id': 'synthetic',
                'pushkey': 'a' * 64, 'data': fixtures[mode]}]})
        rejected = await pushkin._dispatch_notification_unlimited(
            notification, notification.devices[0],
            SimpleNamespace(request_id='synthetic', opentracing_span=None))
        assert rejected == []
        payload = sent[-1]
        assert payload['aps']['alert'] == {'title': '畅聊 ChatFlow', 'body': '您有一条新消息'}
        assert payload['unread_count'] == 2
        if mode == 'silent':
            assert 'sound' not in payload['aps'], 'Sygnal reintroduced sound'
        else:
            assert payload['aps']['sound'] == 'default'
    assert fixtures == original
    print(json.dumps({'result': 'PASS', 'cases': 2, 'sygnal': '0.15.1',
        'payload_source': 'Flutter MatrixPusherService fixture',
        'transport': 'explicit APNs double', 'real_request_construction': True}))


if __name__ == '__main__':
    asyncio.run(run())
