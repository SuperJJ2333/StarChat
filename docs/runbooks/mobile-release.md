# Mobile release runbook

Required GitHub Actions secrets: `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROFILE_BASE64`, `APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`.

The workflow generates the iOS host project on macOS, runs Dart checks, imports signing assets only in the ephemeral runner, builds the IPA, and uploads it to TestFlight. No certificate, profile, private key, or IPA is committed.
