# Flutter client rules
- Matrix plaintext is decrypted and rendered only on the device.
- Never send recovery keys, room keys, plaintext message bodies, or decrypted media to business APIs.
- Financial writes must use Idempotency-Key and parse Decimal values as strings.
- Push payloads may contain only opaque identifiers and generic notification metadata.
