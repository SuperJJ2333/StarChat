# ARM64 update release

User authorized publishing the in-app update prompt and requested ARM64 only to save time. Scope: increment app release identity to 0.3.37+40, retain the already authorized unminified/unobfuscated build configuration, build only standard ARM64 with the existing release signing key, verify signature/version/hash, upload a versioned APK, update only the ARM64 alias, and publish the existing app-update settings through the audited release workflow. Keep minimum supported build unchanged at 3 and retain existing packages for rollback.

The existing update endpoint is architecture-agnostic; this release produces only an ARM64 package but cannot suppress the prompt on old non-ARM64 clients. This limitation was communicated before publication. No new architecture targeting mechanism or changes to E2EE/authentication are in scope.

Evidence: docs/verification/artifacts/2026-09-05/arm64-release/. Reuse just-completed functional validation; run focused release identity/update checks, build guards, remote digest and authenticated published-settings verification.
