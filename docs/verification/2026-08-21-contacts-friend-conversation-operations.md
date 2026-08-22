# Contacts & Friend / Conversation Operations Verification

Date: 2026-08-21

## Environment
- Python virtual environment: `D:\pythonProject\outsource\StarChat\.venv`
- Interpreter: `Python 3.12.10`
- Backend package installation: `python -m pip install -e .\services\business-api` exit 0.
- Flutter executable: `C:\src\flutter\bin\flutter.bat`.

## Red/green evidence
- RED: `.venv\Scripts\python.exe -m pytest tests\business_api\friendship\test_friendship_api.py -q` exited 1 with the intended failures: pending request produced 201 instead of duplicate 409; rejected resend created a different ID.
- GREEN: the same backend command exited 0: `7 passed in 16.36s`.
- Conversation preference RED: Flutter command initially could not resolve `manualUnread` / `restoreForIncomingEvent`; implementation was added and the focused test then exited 0 with `2` passing tests.
- Conversation action sheet: `flutter test test/ui/conversation_action_sheet_test.dart` exited 0 with `1` passing test.

## Current focused verification
- `flutter analyze` exited 0: `No issues found!`.
- `flutter test test/features/matrix/conversation_actions_test.dart test/features/contacts/contact_flow_test.dart` exited 0: `8` tests passed.

## Boundaries review
- Friendship duplicate/reuse checks run in the business service and database transaction.
- Matrix per-room account data stores only unread/pin/hide presentation state; no business API call includes chat plaintext.
- Delete currently hides the selected local conversation after confirmation rather than deleting Matrix history; this requires an explicit Matrix SDK public history/room lifecycle decision before changing destructive chat state.

## Full rerun — 2026-08-21
- BASELINE: `C:\src\flutter\bin\flutter.bat test` (working directory `apps\mobile_flutter`) → `00:12 +229: All tests passed!`; exit 0. Full output: `docs\verification\artifacts\2026-08-21\contacts-friend-design\flutter-test-rerun.txt`.
- MODIFIED: `pwsh.exe -NoProfile -File scripts\verify.ps1` → `172 passed, 1 skipped`; Flutter boundary `19 passed`; Alembic migration through `0020_friend_request_reuse`; OpenAPI drift check PASS; final `Verification: PASS`; exit 0. Full output: `docs\verification\artifacts\2026-08-21\contacts-friend-design\scripts-verify-rerun.txt`.
- ROLLBACK: no rollback was executed because this run performed verification only and did not apply a migration or alter runtime data.
- Static analysis: `C:\src\flutter\bin\flutter.bat analyze` (working directory `apps\mobile_flutter`) → `No issues found!`; exit 0. Full output: `docs\verification\artifacts\2026-08-21\contacts-friend-design\flutter-analyze-rerun.txt`.
- Diff validation: `git diff --check` → exit 0.
