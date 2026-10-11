"""Versioned ordinary iOS sound policy, evaluated at each APNs send attempt.

No device identifier, policy value or payload is logged here. A policy can only
remove sound; alert/badge and the persisted pusher defaults remain unchanged.
"""
from copy import deepcopy
from datetime import datetime, timezone
from enum import Enum
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

POLICY_KEY = "chatflow_ios_policy"
FIELDS = frozenset(("v", "revision", "timezone", "dnd_start_minutes",
                    "dnd_end_minutes", "dnd_enabled"))
MAX_REVISION = 9007199254740991
_ZONE_NAME = re.compile(r"[A-Za-z0-9_+/-]{1,128}\Z")


class SoundReason(str, Enum):
    NON_ALERT = "non_alert_unchanged"
    LEGACY = "legacy_unchanged"
    INVALID_POLICY = "invalid_policy"
    UNSUPPORTED_VERSION = "unsupported_version"
    INVALID_TIMEZONE = "invalid_timezone"
    DISABLED = "dnd_disabled"
    EMPTY_WINDOW = "empty_window"
    OUTSIDE = "outside_dnd"
    ACTIVE = "dnd_active"


def utc_now():
    return datetime.now(timezone.utc)


def _decision(data, push_type):
    # aioapns uses an enum, while test/custom integrations can supply its value.
    if getattr(push_type, "value", push_type) not in (None, "alert"):
        return False, SoundReason.NON_ALERT
    if not isinstance(data, dict) or POLICY_KEY not in data:
        return False, SoundReason.LEGACY
    rules = data[POLICY_KEY]
    if type(rules) is not dict or set(rules) != FIELDS:
        return True, SoundReason.INVALID_POLICY
    if type(rules["v"]) is not int:
        return True, SoundReason.INVALID_POLICY
    if rules["v"] != 1:
        return True, SoundReason.UNSUPPORTED_VERSION
    if (type(rules["revision"]) is not int
            or not 1 <= rules["revision"] <= MAX_REVISION
            or type(rules["dnd_enabled"]) is not bool):
        return True, SoundReason.INVALID_POLICY
    start, end = rules["dnd_start_minutes"], rules["dnd_end_minutes"]
    if any(type(value) is not int or not 0 <= value < 1440 for value in (start, end)):
        return True, SoundReason.INVALID_POLICY
    name = rules["timezone"]
    if (type(name) is not str or not _ZONE_NAME.fullmatch(name)
            or name in ("localtime", "posixrules")
            or name.startswith(("/", "posix/", "right/"))):
        return True, SoundReason.INVALID_TIMEZONE
    try:
        zone = ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return True, SoundReason.INVALID_TIMEZONE
    if not rules["dnd_enabled"]:
        return False, SoundReason.DISABLED
    if start == end:
        return False, SoundReason.EMPTY_WINDOW
    # UTC -> local wall minute is unambiguous even in DST folds and gaps.
    local = utc_now().astimezone(zone)
    minute = local.hour * 60 + local.minute
    active = start <= minute < end if start < end else minute >= start or minute < end
    return active, SoundReason.ACTIVE if active else SoundReason.OUTSIDE


def apply_sound_policy(payload, data, push_type):
    outgoing = deepcopy(payload)
    silent, reason = _decision(data, push_type)
    if silent and isinstance(outgoing.get("aps"), dict):
        outgoing["aps"].pop("sound", None)
    return outgoing, reason
