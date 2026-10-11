# Initialized calibration failure follow-up

Base: c3050684c07f955b0e9f449e909cea05ec36786e. Review identified that a failed later directory scan left a previously complete quota snapshot eligible for eviction, contradicting the fail-safe contract.

The new test first initializes a real 19-byte object and SQLite snapshot, then injects a directory-list failure. RED (recalibration-red.log) observed canEvict=true instead of false. The fix clears eligibility before propagating the scan error and retains a dirty marker so a later process rebuilds instead of trusting old completeness. It preserves files and accounting; a successful retry restores eligibility.

Verification on 2026-10-11:
- recalibration-green.log: 42 tests PASS, exit 0 (quota index, media index phase2, cache clear).
- recalibration-analyze.log: flutter analyze --no-pub, 0 issues, exit 0.
- No dependency/native/protocol changes. Existing unchanged boundary and repository gates from c3050684 are reused. No full suite, device/RSS or production claim.
- Timings: log file modification times and SHA256 identities are in recalibration-input-hashes.json. Active/tool wait durations were not measured.
- Next: independent review and parent integration; R10 work will use a separate checkout.
