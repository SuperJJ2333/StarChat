# iOS enterprise publication and isolated updates

User explicitly requested distributing the signed iOS IPA and enabling iOS update prompts without changing Android delivery. Implementation follows that authorization; no additional approval is needed for the necessary correction.

Inspection found the supplied 2073 enterprise IPA embeds an unrelated application identifier in both its profile and signed Runner entitlements, and injects two additional libraries. The input build also disables in-app update checks. Do not activate it as a verified normal-install release. Preserve the provided file and evidence; require corrected enterprise signing for the final input.

1. Keep Android default update endpoint behavior and settings unchanged. Add explicit `platform=ios` projection using separate iOS setting keys, returning unconfigured if no iOS release exists. Unknown platforms fail validation. Keep authentication and audit boundaries intact.
2. Client requests the iOS projection only on native iOS; Android retains its exact legacy request. Enable update checks in iOS CI and increment the unpublished iOS candidate to 0.3.70 / 2074. Old packages compiled with update checks off cannot be remotely enabled and require initial manual website upgrade.
3. Add failing platform-isolation tests first, implement, check OpenAPI, run focused and full applicable gates, specification review then quality review. Backend agent owns update router/settings constants/backend tests/generated OpenAPI; root owns client routing/workflow/version and delivery evidence. No concurrent edits to the same files.
4. Build and validate a concrete replacement re-signing input. Do not replace Android APK/latest settings or send a global notification as an iOS workaround. Do not activate iOS update settings until a correctly signed and install-verified enterprise artifact exists.
5. Prepare versioned HTTPS IPA/manifest/download entries after valid signing. Read and preserve current live site and Android release state before deployment; retain rollback copies and verify public hashes. The existing backend service must be inspected before any incremental deployment.
