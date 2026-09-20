# Mi6 rate-limit follow-up

Authorization: user directly requests continued repair; existing production authority persists; no public release/update popup. Base bfd8d89a. Design under existing chat reliability plan: isolate background association quota from foreground recovery; publish only missing server-verified associations; narrowly handle transient direct recovery throttling without financial retries, identity bypass or duplicate creation. Red packet target needs clarification: production environment20000.00, no database override; display correctly reflects current backend configuration.

- [x] Client convergence tests RED/GREEN: repeated unchanged sync produces no association writes; new verified room published once after server acknowledgement; failed publication remains retryable.
- [x] Server independent association/recovery buckets with finite limits and isolation tests.
- [x] Direct recovery bounded typed429 retry, preserve attempt/account identity and fail closed on actual denial.
- [x] Confirm red packet desired configuration, apply via audited SettingService if requested; readback backend and device.
- [x] Specification then quality review, relevant gates and production minimal candidate/rollback validation.
- [x] Rebuild fixed-signature debug, install Mi6 preserving data, evidence and no update popup.

Owners: root convergence/tests/docs/config/build; recovery_rate_isolation server route/tests; send_rate_retry coordinated direct gateway/tests. Evidence excludes message bodies/credentials. Actual device outbox inspected in memory only: four failed entries with rate-limit message. Production60minute logs: associations70x429, resolve10x429. No Matrix send429 observed in same window. This supersedes prior unproven timing hypothesis.

User confirmed200.00; production audited override applied and endpoint projection verified. Initial spec pending-target text above is historical. Device UI display still awaits user re-entry; new APK is not required for config refresh.

Final: fullverifyPASS, productionfixed andTLS/auth/configchecksPASS; Mi6debug2/2141installed/hashverified; userbusinessacceptancepending, not claimed.
