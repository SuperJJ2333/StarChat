"""Matrix metadata -> per-device generic push whitelist.

Legacy/calls retain type and CID only. Opted-in ordinary messages additionally
carry session-scoped SHA256 room/event associations, never raw identifiers or
content. These pseudonymous associations are not anonymity or authorization.
"""
from dataclasses import dataclass, field
import hashlib
import re


@dataclass(frozen=True)
class NativeEnvelope:
    scope: str
    room_key: str
    event_key: str

    def payload(self) -> dict:
        return {'type': 'message', 'v': 1, 'scope': self.scope,
                'room_key': self.room_key, 'event_key': self.event_key}


@dataclass(frozen=True)
class SanitizedPush:
    kind: str  # 'message' | 'call'
    cids: list[str]
    envelopes: dict[str, NativeEnvelope] = field(default_factory=dict)


def sanitize_notification(body: dict, app_id: str) -> SanitizedPush | None:
    """解析 Matrix Push Gateway /notify 请求体。

    返回 None 表示无目标设备（或 app_id 不匹配）——调用方直接 200 空回。
    Raw identifiers/content never enter the result; valid v1 targets contain
    only the reviewed scoped association digests.
    """
    notification = body.get("notification")
    if not isinstance(notification, dict):
        return None
    devices = notification.get("devices")
    if not isinstance(devices, list):
        return None

    # 消息类型：来电信令（m.call.*）→ call；其余（消息/加密消息/…）→ message。
    event_type = notification.get("type")
    kind = (
        "call"
        if isinstance(event_type, str) and event_type.startswith("m.call")
        else "message"
    )

    if len(devices) > 100:
        raise ValueError('device limit')
    targets: dict[str, NativeEnvelope | None] = {}
    blocked: set[str] = set()
    for device in devices:
        if not isinstance(device, dict) or device.get('app_id') != app_id:
            continue
        cid = device.get('pushkey')
        if not isinstance(cid, str) or not cid or len(cid.encode('utf-8')) > 1024:
            continue
        data = device.get('data')
        envelope = None
        if kind != 'call' and isinstance(data, dict) and any(
            key.startswith('chatflow_push_') for key in data if isinstance(key, str)
        ):
            version, scope = data.get('chatflow_push_v'), data.get('chatflow_push_scope')
            revision = data.get('chatflow_push_revision')
            identifiers = [notification.get('room_id'), notification.get('event_id')]
            valid = (type(version) is int and version == 1
                     and isinstance(scope, str) and re.fullmatch('[0-9a-f]{64}', scope)
                     and type(revision) is int and 0 < revision <= 2**53 - 1
                     and all(isinstance(value, str) and 0 < len(value.encode('utf-8')) <= 1024
                             for value in identifiers))
            if not valid:
                blocked.add(cid)
                continue
            digest = lambda value: hashlib.sha256((scope + '\0' + value).encode('utf-8')).hexdigest()
            envelope = NativeEnvelope(scope, digest(identifiers[0]), digest(identifiers[1]))
        if cid in targets and targets[cid] != envelope:
            blocked.add(cid)
        targets[cid] = envelope
    cids = [cid for cid in targets if cid not in blocked]
    if not cids:
        return None
    return SanitizedPush(kind=kind, cids=cids,
                         envelopes={cid: targets[cid] for cid in cids if targets[cid] is not None})
