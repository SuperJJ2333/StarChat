# QR and friendship production delivery

Authorized by the user's 2026-09-05 request to deploy the server fixes and install a debug build on MI 6. The existing permission to defer Figma applies.

Root owns deployment scripts/evidence, generated OpenAPI, integration validation and APK delivery. Friendship agents own the files listed in their focused plans. QR agent owns `app/api/groups.py`, the necessary Matrix gateway methods and QR tests.

1. Compare the running production source with local changes; deploy only QR modules/migration, required Matrix methods, friendship request projection/preference ownership and Moments visibility fixes.
2. Before deployment, fix the identified QR blockers with failing/passing tests: private-room admission, token issue replay, retry after failed redeem/approval, and conflicting revoke keys. Preserve room membership, bans and moderator checks.
3. Validate focused suites, API schema, full repository verification and Flutter analysis. Record pre-existing failures separately.
4. Keep a server-side database backup and immutable previous image. Build a version-tagged overlay of the actual production image; apply only the additive 0036 migration and restart business-api. Leave Matrix and other services running.
5. Check health, schema and migration after deployment. On failure restore the previous image without dropping the new tables. Keep source backups and deployment commands on the server.
6. Build standard ARM64 debug 0.3.36 from source without obfuscation or packing. Verify artifact metadata/signature; install with data-preserving `adb install -r -t` on MI 6 cbd0156b and confirm the installed version.

Verification evidence and temporary files belong under `docs/verification/artifacts/2026-09-05/friendship-deploy/`.
