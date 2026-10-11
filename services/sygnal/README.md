# Sygnal 0.15.1 iOS sound policy overlay

This candidate evaluates ordinary iOS notification sound immediately before each
APNs request, including retries. It never removes visible alerts or badges, adds
sound, changes APNs rejection/retry handling, or changes VoIP/background push types.
There are no new dependencies, configuration keys or credential files.

The base is `matrixdotorg/sygnal:v0.15.1`, pinned by digest
`sha256:0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba`.
`vendor/apnspushkin.py` is from the
[official v0.15.1 tag](https://github.com/matrix-org/sygnal/blob/v0.15.1/sygnal/apnspushkin.py),
whose SHA256 is `e87d32765b4d3f1cd24102ad25f87f1f4a53e8cd3666cc376798d915ab0131b9`.
The build checks that exact installed source before replacing it. The original
copyright header and Apache-2.0 [LICENSE](vendor/LICENSE) are retained. The patch
adds one policy call before NotificationRequest and removes token/room/event
values from the existing send/rejection log messages. Upgrade this overlay only
after comparing the new upstream dispatch path and rerunning these contracts.

Ordinary pusher `data.chatflow_ios_policy` is a strict object:

```json
{"v":1,"revision":1,"timezone":"Asia/Hong_Kong","dnd_start_minutes":1380,"dnd_end_minutes":480,"dnd_enabled":true}
```

- `v` is integer1; revision is integer1..9007199254740991; minutes are integer0..1439;
  enabled is Boolean. Booleans are not valid integers. There are no extra fields.
- timezone is a valid IANA zone name, 1..128 ASCII characters. The pinned image's
  timezone database is used. Missing zones, malformed objects and unknown versions
  fail closed to a silent visible notification with a fixed reason enum. They do
  not reject/delete the pusher. No timezone, policy or device value is logged.
- UTC is sampled at each actual send attempt and converted to the local wall
  minute. The window is start-inclusive/end-exclusive, wraps midnight when start
  exceeds end, and is disabled for equal endpoints. UTC conversion handles both
  occurrences of a DST fold and never invents minutes in a DST gap.
- Missing policy means legacy behavior. Static sound-off is the absence of
  `default_payload.aps.sound`; static sound-on is `default`. DND only removes the
  outgoing sound key. A fresh deep copy preserves original defaults and retries,
  including a retry which crosses the window's end.
- E2EE event-id-only data cannot prove an attention/mention exception. This policy
  does not infer one. Client-only attention exceptions are not a server guarantee.

Build from the repository root:

```powershell
docker build --network none --pull=false -t starchat/sygnal:im-ios-policy-20261011 services/sygnal
docker run --rm --network none --mount "type=bind,source=<absolute tests/sygnal>,target=/tests,readonly" --entrypoint python starchat/sygnal:im-ios-policy-20261011 /tests/ios_policy_contract.py
```

The contract uses the real Sygnal Notification parsing, both payload builders,
truncation, retry loop and APNs NotificationRequest. Only UTC time and the APNs
transport are test doubles; no certificate/config is loaded and networking is
disabled. The upstream APNs/truncation regressions also run on this image.

Deployment is separate: freeze the actual current image/config and source hashes,
build the reviewed overlay against the verified compatible base, preserve existing
credential mounts/config and all other containers, then switch only Sygnal. Verify
the installed two source hashes, readiness, unauthenticated gateway behavior and
ordinary/VoIP routing. Rollback uses the frozen previous image/config; no pusher
deletion or database migration is required. Gateway rollout must precede client
claims that a stored DND window is enforced. Apple acceptance, system Focus/silent
settings and real device audible playback remain independent acceptance checks.
