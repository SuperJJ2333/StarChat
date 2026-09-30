"""Private, domain-separated references for authenticated diagnostic records."""

import hashlib
import hmac
from typing import Literal


def diagnostic_ref(secret: bytes, domain: Literal['subject', 'device'], value: str) -> str:
    if len(secret) < 32 or not value or domain not in ('subject', 'device'):
        raise ValueError('Invalid diagnostic identity input')
    prefix = b'chatflow/diagnostics/' + domain.encode('ascii') + b'/v1\0'
    return hmac.new(secret, prefix + value.encode('utf-8'), hashlib.sha256).hexdigest()
