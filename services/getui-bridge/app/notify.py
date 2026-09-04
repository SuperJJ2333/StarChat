"""Matrix 通知 → 脱敏推送规格。

E2EE 边界的核心：入站的全部业务字段（event_id/room_id/正文/发送者/
房间名/附件）在本模块被丢弃；出站只保留：
- kind（message/call，仅用于选择通用文案）；
- cids（设备映射：Matrix pusher 的 pushkey，即个推 CID）。
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class SanitizedPush:
    kind: str  # 'message' | 'call'
    cids: list[str]


def sanitize_notification(body: dict, app_id: str) -> SanitizedPush | None:
    """解析 Matrix Push Gateway /notify 请求体。

    返回 None 表示无目标设备（或 app_id 不匹配）——调用方直接 200 空回。
    任何业务字段都不进入返回值。
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

    cids = [
        device["pushkey"]
        for device in devices
        if isinstance(device, dict)
        and device.get("app_id") == app_id
        and isinstance(device.get("pushkey"), str)
        and device["pushkey"]
    ]
    if not cids:
        return None
    return SanitizedPush(kind=kind, cids=list(dict.fromkeys(cids)))
