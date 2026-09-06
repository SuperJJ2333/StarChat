# Profile entry verification

Scope: `app_home.dart`, `matrix_home_page.dart`, `profile_message_route_wiring_test.dart`, and `group_member_profile_test.dart`.

Root cause: RoomPage's contact profile route omitted its message callback; the group public-profile route omitted the avatar URL already supplied by the business lookup API. ContactsPage itself already forwarded its callback and used the Matrix user ID.

Implementation: all external room creation routes forward the message action. AppHome uses its existing canonical DirectChatController, with the peer's Matrix ID, and resolves the returned room before navigation. The contacts tab forwards its existing opener into subsequent room pages. No friendship request is created by opening a profile or messaging action.

Evidence:
- `member-avatar-red.log`: expected public avatar URL, actual null.
- `profile-route-red.log`: both route continuity assertions fail before wiring.
- `profile-route-green.log`: both assertions pass after wiring.
- `profile-entry-focused-green.log`: 36 tests pass, covering wiring, group profile navigation, contact actions, direct-room safety and canonical-room reuse.
- `profile-entry-analyze.log`: no issues in the four owned Dart files.

The route audit is a source-based completeness check because the production root opens a real Matrix room. Existing widget tests separately exercise the contact message button and group profile navigation. This is not device or production network verification.

Specification review: public avatar metadata is preserved; message routes reuse the canonical encrypted direct-chat gate; the existing friend/stranger/self dispatch remains intact; no automatic friend acceptance or financial changes occur.

Quality/privacy review raised a required follow-up for the root-owned room change: after rendering local remarks, the shared display name must not be reused for outgoing mention text or nudge `target_display_name`. NudgeService serializes that field into the encrypted group event, visible to other members. Root was informed to retain public names for outgoing content and local remarks only for rendering. Final disposition belongs to root's review evidence.

## Final independent re-review

The follow-up is resolved in the current source. `_senderDisplayName` renders the viewer's contact remark locally; `_publicSenderName` reads only `primaryDisplayName` or the Matrix public display name. Avatar mention text and all four nudge callbacks use `publicDisplayName`. Neither path serializes the viewer's private remark or tags.

All five requested paths were traced: new-friend profile messaging and group-member friend profile messaging both retain the canonical message callback; stranger group profile navigation preserves the business avatar URL; group sender labels use the viewer's own contact override; all four message-avatar variants reach the shared friend/stranger/self profile dispatcher. The direct-chat details avatar now uses that same dispatcher, closing the alternate incomplete profile path.

No remaining blocking specification or privacy finding was identified. This review does not claim a physical-device or live-server run; the root's release checks remain separate.
