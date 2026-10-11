"""Real pinned Sygnal dispatch; only APNs transport and UTC clock are doubles.

Run in the 0.15.1 image with --network none. No config or credentials are loaded.
The optional clock module permits the same behavior tests against the base image
for RED evidence; its absence is not itself treated as the failing assertion.
"""
import copy
from datetime import datetime
import importlib
import logging
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import opentracing
from aioapns.common import PushType
from sygnal import apnspushkin
from sygnal.apnspushkin import ApnsPushkin
from sygnal.notifications import Notification

try:
    policy_module = importlib.import_module("sygnal.chatflow_ios_policy")
except ModuleNotFoundError:
    policy_module = None


def utc(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def policy(**changes):
    values = dict(v=1, revision=1, timezone="Asia/Hong_Kong",
                  dnd_start_minutes=1380, dnd_end_minutes=480, dnd_enabled=True)
    values.update(changes)
    return values


class PolicyContract(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.now = utc("2026-10-11T15:00:00Z")  # 23:00 Hong Kong
        if policy_module is not None:
            clock = patch.object(policy_module, "utc_now", lambda: self.now)
            clock.start()
            self.addCleanup(clock.stop)
        self.pushkin = object.__new__(ApnsPushkin)
        self.pushkin.name = "synthetic-policy-test"
        self.pushkin.sygnal = SimpleNamespace(tracer=opentracing.Tracer(), reactor=None)
        self.pushkin.push_type = PushType.ALERT
        self.pushkin.get_config = lambda *args: False
        self.sent = []

        async def capture(request):
            self.sent.append(copy.deepcopy(request.message))
            return SimpleNamespace(status=200, is_successful=True)

        self.pushkin._send_notification = capture

    async def send(self, rules="normal", sound=True, full=False):
        aps = {"alert": {"title": "Synthetic alert", "body": "Generic notification"},
               "badge": 3, "mutable-content": 1}
        if sound:
            aps["sound"] = "default"
        data = {"default_payload": {"aps": aps}, "format": "event_id_only"}
        if rules != "missing":
            data["chatflow_ios_policy"] = policy() if rules == "normal" else rules
        original = copy.deepcopy(data)
        raw = {"event_id": "$synthetic-event", "room_id": "!synthetic-room:test",
               "counts": {"unread": 2}, "devices": [{"app_id": "synthetic",
               "pushkey": "b" * 64, "data": data}]}
        if full:
            raw.update(type="m.room.encrypted", sender="@synthetic:test")
        n = Notification(raw)
        rejected = await self.pushkin._dispatch_notification_unlimited(
            n, n.devices[0], SimpleNamespace(request_id="synthetic", opentracing_span=None))
        self.assertEqual(rejected, [])
        self.assertEqual(data, original, "policy must not mutate persisted defaults")
        payload = self.sent[-1]
        self.assertIn("alert", payload["aps"])
        self.assertIn("badge", payload["aps"])
        self.assertEqual(payload["aps"]["mutable-content"], 1)
        self.assertNotIn("chatflow_ios_policy", payload)
        return payload

    async def test_dnd_start_included_end_excluded_and_midnight_wrap(self):
        for instant, silent in [
            ("2026-10-11T14:59:59Z", False), ("2026-10-11T15:00:00Z", True),
            ("2026-10-11T15:59:59Z", True), ("2026-10-11T16:00:00Z", True),
            ("2026-10-11T23:59:59Z", True), ("2026-10-12T00:00:00Z", False),
        ]:
            with self.subTest(instant=instant):
                self.now = utc(instant)
                self.assertEqual("sound" not in (await self.send())["aps"], silent)

    async def test_same_day_disabled_equal_and_half_hour_timezone(self):
        for rules, instant, silent in [
            (policy(dnd_start_minutes=600, dnd_end_minutes=660), "2026-10-11T02:00:00Z", True),
            (policy(dnd_start_minutes=600, dnd_end_minutes=660), "2026-10-11T03:00:00Z", False),
            (policy(dnd_enabled=False), "2026-10-11T15:00:00Z", False),
            (policy(dnd_start_minutes=0, dnd_end_minutes=0), "2026-10-11T15:00:00Z", False),
            (policy(timezone="Asia/Kolkata"), "2026-10-11T17:30:00Z", True),
        ]:
            with self.subTest(rules=rules, instant=instant):
                self.now = utc(instant)
                self.assertEqual("sound" not in (await self.send(rules))["aps"], silent)

    async def test_dst_fold_both_real_instants_and_spring_gap(self):
        for instant, start, end, silent in [
            ("2026-11-01T05:30:00Z", 60, 120, True),
            ("2026-11-01T06:30:00Z", 60, 120, True),
            ("2026-11-01T07:00:00Z", 60, 120, False),
            ("2026-03-08T06:59:59Z", 120, 180, False),
            ("2026-03-08T07:00:00Z", 120, 180, False),
            ("2026-03-08T07:00:00Z", 180, 240, True),
        ]:
            with self.subTest(instant=instant, start=start):
                self.now = utc(instant)
                result = await self.send(policy(timezone="America/New_York",
                    dnd_start_minutes=start, dnd_end_minutes=end))
                self.assertEqual("sound" not in result["aps"], silent)

    async def test_present_invalid_policy_is_silent_not_rejected(self):
        invalid = [None, [], "invalid", {}, policy(v=2), policy(v=True),
            policy(revision=0), policy(revision=True), policy(revision=2**53),
            policy(revision="1"), policy(dnd_enabled=1), policy(dnd_start_minutes=True),
            policy(dnd_start_minutes=-1), policy(dnd_end_minutes=1440),
            policy(dnd_end_minutes=2.5), policy(timezone=""), policy(timezone="../UTC"),
            policy(timezone="Unknown/Zone"), policy(timezone="localtime"),
            policy(timezone="posixrules"), policy(timezone=1),
            policy(timezone="a" * 129), policy(unknown=True)]
        for rules in invalid:
            with self.subTest(rules=rules):
                self.assertNotIn("sound", (await self.send(rules))["aps"])

    async def test_static_off_dominates_outside_dnd_and_legacy(self):
        self.now = utc("2026-10-12T04:00:00Z")
        for rules in ("missing", policy(), policy(dnd_enabled=False), policy(v=2)):
            with self.subTest(rules=rules):
                self.assertNotIn("sound", (await self.send(rules, sound=False))["aps"])

    async def test_legacy_voip_and_other_non_alert_types_are_unchanged(self):
        self.assertEqual((await self.send("missing"))["aps"]["sound"], "default")
        for push_type in (PushType.VOIP, PushType.BACKGROUND):
            self.pushkin.push_type = push_type
            for rules in (policy(), policy(v=2)):
                with self.subTest(push_type=push_type, rules=rules):
                    self.assertEqual((await self.send(rules))["aps"]["sound"], "default")

    async def test_unset_push_type_and_full_payload_use_same_policy(self):
        self.pushkin.push_type = None
        self.assertNotIn("sound", (await self.send())["aps"])
        self.assertNotIn("sound", (await self.send(full=True))["aps"])

    async def test_each_retry_recomputes_send_time_without_mutating_base(self):
        self.now = utc("2026-10-11T14:59:59Z")
        attempts = []

        async def capture(request):
            attempts.append(copy.deepcopy(request.message))
            self.sent.append(copy.deepcopy(request.message))
            return SimpleNamespace(status=503 if len(attempts) == 1 else 200,
                is_successful=len(attempts) > 1, description="InternalServerError")

        async def advance(*args, **kwargs):
            self.now = utc("2026-10-11T15:00:00Z")

        self.pushkin._send_notification = capture
        with patch.object(apnspushkin, "twisted_sleep", advance):
            await self.send()
        self.assertEqual(attempts[0]["aps"]["sound"], "default")
        self.assertNotIn("sound", attempts[1]["aps"])

    async def test_dnd_suppression_does_not_remove_later_sound(self):
        first = await self.send()
        self.now = utc("2026-10-12T00:00:00Z")
        second = await self.send()
        self.assertNotIn("sound", first["aps"])
        self.assertEqual(second["aps"]["sound"], "default")

    async def test_retry_after_dnd_end_restores_original_static_policy(self):
        self.now = utc("2026-10-11T23:59:59Z")
        attempts = []

        async def capture(request):
            attempts.append(copy.deepcopy(request.message))
            self.sent.append(copy.deepcopy(request.message))
            return SimpleNamespace(status=503 if len(attempts) == 1 else 200,
                is_successful=len(attempts) > 1, description="InternalServerError")

        async def advance(*args, **kwargs):
            self.now = utc("2026-10-12T00:00:00Z")

        self.pushkin._send_notification = capture
        with patch.object(apnspushkin, "twisted_sleep", advance):
            await self.send()
        self.assertNotIn("sound", attempts[0]["aps"])
        self.assertEqual(attempts[1]["aps"]["sound"], "default")

    async def test_policy_logs_only_fixed_reasons_not_payload_or_device(self):
        with self.assertLogs("sygnal", level="INFO") as logs:
            await self.send(policy(timezone="Sensitive/Invalid"))
        combined = " ".join(logs.output)
        self.assertIn("invalid_timezone", combined)
        for secret in ("Sensitive/Invalid", "b" * 64, "!synthetic-room", "$synthetic-event",
                       "Generic notification"):
            self.assertNotIn(secret, combined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
