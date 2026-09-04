"""Dormant placeholder pushkin (deployed 2026-09-04).

sygnal v0.15.x refuses to boot with zero apps. Until FCM credentials are
configured (docs/PUSH_SETUP.md in the StarChat repo), this pushkin logs
and rejects every dispatch so the gateway can run healthy and dormant.
Swap `apps:` to the real `com.liuhetong.mobile.android` FCM entry and
restart sygnal once credentials exist; then delete this file if you like.
"""

import logging

from sygnal.notifications import ConcurrencyLimitedPushkin

logger = logging.getLogger(__name__)


class NoopPushkin(ConcurrencyLimitedPushkin):
    async def dispatch_notification(self, n, device, context):
        logger.info(
            "placeholder pushkin for app %s: no push credentials configured yet",
            self.name,
        )
        # Reject the pushkey so the homeserver knows delivery is unavailable.
        return [device.pushkey]
