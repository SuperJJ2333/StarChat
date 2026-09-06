# Forward confirmation and private friend preferences

Approved scope: user's 2026-09-05 bug report explicitly requests owner-only remarks/tags, working group avatars, press feedback and a bottom confirmation after choosing a chat. Earlier permission to defer Figma remains applicable.

Root owns chat_forward_picker_page.dart, encrypted_media_view.dart and picker tests. Separate agents own friend privacy and room-page avatars; no concurrent file edits.

1. Add failing widget tests for deferred sending, bottom recipient/content card, cancel, multi-select, retry and input order.
2. Keep the independent picker; add animated Cupertino controls and a scrollable safe-area confirmation sheet. Confirm invokes forwarding, cancellation never sends. Return true only on success.
3. Make incoming friend request projection and acceptance local cache owner-private. Test both actor directions.
4. Load group members into authenticated mosaic avatars and pass content previews from room messages.
5. Run focused tests/analyze, repository verification, specification then quality review. Record evidence under docs/verification. Deploy only isolated privacy server files and install ARM64 debug on MI 6 when verified; preserve unrelated work and device data.
