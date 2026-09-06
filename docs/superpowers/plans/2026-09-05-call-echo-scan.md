# Call echo and scanner repair

Approved scope is the user's explicit 2026-09-05 request: repair voice/video echo; scanner must cover the tab bar, provide a photo-only gallery matching the chat picker, and open the existing My QR page. Figma deferral remains authorized.

Root owns scan_qr_page.dart, discovery_page.dart, matrix_home_page.dart scanner route, image_picker_page.dart, device_gallery_source.dart, focused tests and integration evidence. Audio agent owns call audio/renderer files and tests, with no overlap.

1. Trace call rendering, capture constraints and audio routes before changing audio; write a failing regression for any proven defect. Do not disable uplink microphone or weaken encrypted calls to silence echo.
2. Scanner opens on root navigator. Bottom actions: My QR and Gallery. Gallery reuses ImagePickerPage's album/grid/preview style in photo-only single-selection mode; query and permission scope both exclude videos, including after switching albums/resuming. Confirm scans the original local image using the existing scanner engine, with readable failure and cancellation states. Camera pauses while auxiliary pages are visible and resumes on return.
3. My QR loads the signed-in user's profile through ProfileGateway and opens MyQrCodePage; preserve existing explicit confirmation flows for adding friends/joining groups.
4. Test-first gallery/query/navigation/scan tests and audio regressions, focused analyzer, existing picker/call suites, UI contract and required full verify. Keep all WIP. Save evidence under docs/verification/artifacts/2026-09-05/call-echo-scan/.
5. Build/install ARM64 debug on MI 6 for testing if device is available, preserving data. Do not automatically publish another production version in this repair turn. Real acoustic elimination requires a two-device call in separate rooms; no calls to third parties are authorized.
