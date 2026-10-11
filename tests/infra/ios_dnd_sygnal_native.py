"""Real generated Flutter policy -> reviewed Sygnal -> APNs request fixture.

Use the reviewed candidate image with --network none. Only UTC clock and APNs
transport are doubles; no configuration, certificates or real token is loaded.
"""
import asyncio
import copy
from datetime import datetime
import json
import logging
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

import opentracing
from sygnal.apnspushkin import ApnsPushkin
from sygnal import chatflow_ios_policy
from sygnal.notifications import Notification


async def run():
    logging.disable(logging.CRITICAL)
    fixtures = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    original = copy.deepcopy(fixtures)
    pushkin = object.__new__(ApnsPushkin)
    pushkin.name = 'synthetic'
    pushkin.sygnal = SimpleNamespace(tracer=opentracing.Tracer())
    pushkin.push_type = 'alert'
    pushkin.get_config = lambda *args: False
    sent = []

    async def capture(request):
        sent.append(copy.deepcopy(request.message))
        return SimpleNamespace(status=200, is_successful=True)

    pushkin._send_notification = capture
    cases = [
        ('scheduled', '2026-10-11T14:59:59+00:00', True),
        ('scheduled', '2026-10-11T15:00:00+00:00', False),
        ('scheduled', '2026-10-12T00:00:00+00:00', True),
        ('silent', '2026-10-12T04:00:00+00:00', False),
        ('unavailable', '2026-10-12T04:00:00+00:00', False),
    ]
    for mode, instant, sound in cases:
        notification = Notification({'event_id': '$synthetic', 'room_id': '!synthetic:test',
            'counts': {'unread': 2}, 'devices': [{'app_id': 'synthetic',
                'pushkey': 'a' * 64, 'data': fixtures[mode]}]})
        with patch.object(chatflow_ios_policy, 'utc_now',
                          lambda: datetime.fromisoformat(instant)):
            rejected = await pushkin._dispatch_notification_unlimited(
                notification, notification.devices[0],
                SimpleNamespace(request_id='synthetic', opentracing_span=None))
        assert rejected == []
        payload = sent[-1]
        assert payload['aps']['alert'] == {'title': '畅聊 ChatFlow', 'body': '您有一条新消息'}
        assert payload['unread_count'] == 2
        assert ('sound' in payload['aps']) == sound, (mode, instant)
        assert 'chatflow_ios_policy' not in payload
    assert fixtures == original
    print(json.dumps({'result': 'PASS', 'cases': len(cases),
        'payload_source': 'Flutter IosPushPolicy persistent preparation + MatrixPusherService',
        'transport': 'explicit APNs double', 'clock': 'UTC double',
        'real_request_construction': True}))


if __name__ == '__main__':
    asyncio.run(run())
