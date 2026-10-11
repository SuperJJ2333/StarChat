# Separately authorized minimal warning structure observation

Status: **LOGGER_STRUCTURE_OBSERVED_CAUSE_UNRESOLVED**. This adds locating evidence only; it does not change1176fb2b's strict report or either earlier observation. Root authorized one additional read limited to safe logger names and fixed literal booleans, with no raw message or exception output.

One jumper invocation exited0. Server observation UTC `2026-10-11T10:49:40.857101+00:00`; worker log window since `2026-10-11T10:39:52Z`, tail cap2000, timeout12s. Script SHA256 `571a5f9f7f20ca7ed6af9f6bb38387b34f9fa99e16914905459d145a593c7656`. Pure local synthetic tests checked supported text/JSON logger formats, strict `[A-Za-z][A-Za-z0-9_.-]{0,80}` acceptance, overlength/path/identifier rejection and suppression of sample message/parameter markers.

Observed:

- Four lines matched the `WARNING`/`WARN` word filter. No logger passed extraction; `unknown_logger_lines=4` and `logger_counts={}`.
- `sqlalchemy_literal=false`, `deprecation_literal=false`, `optional_provider_literal=false`, `connection_literal=false`.
- Raw log lines were held only in memory. No message, mode, parameter, path, event/user ID or exception text was printed or persisted.
- The original report and both earlier receipts/metadata were checked byte-for-byte in the same local checkout before/after this invocation and were unchanged.

The structure parser recognizes anchored default `WARNING:logger:message`, selected explicitly delimited timestamp formats, and JSON `level`/`logger` keys. An unrecognized format is reported as unknown; it does not establish that the application has no logger. The filter includes `WARN`, while the prior classification used only `WARNING`; the counts must not be treated as a comparable warning rate or proof of three new warnings. These literals and names cannot establish root cause or harmlessness. Root received the unresolved result; no further remote lookup or recovery was attempted.

Local static follow-up shows candidate `services/business-worker/app/main.py:199` calls `logging.basicConfig(level=...)` without an explicit formatter. This is source context only and does not prove the runtime warning's formatter or origin. No business module was imported, no temporary container was started, and no service, configuration or production data was written.

Evidence: `warning-structure-result.json`, `warning-structure-metadata.json`, `warning-structure-local-proof.json`, and `warning_structure_readonly.py`. Prior conclusions remain in `REPORT.md` unchanged.
