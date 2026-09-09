# Shared identity consumer verification

Scope: UI identity consumers, isolated worktree `.worktrees/redmi-polish-20260909`; no deployments, device installs, or commits performed by this agent.

Owned Flutter files: `ui/moments/wechat_moment_tile.dart`; Moments feed/detail/personal/profile preview; `contacts_page.dart`, `add_friend_profile_page.dart`, `contact_profile_sections.dart`, `group_address_list_page.dart`; `global_search_page.dart`; `group_chat_info_page.dart`. Tests: `moment_identity_consumers_test.dart`, one expectation in `moments_flow_test.dart`.

Behavior: repository-local identity projection drives author, likes, comment/reply author, reply composer header, search results, friend/user profile, personal timeline title, group members/search/pickers and mosaic avatars. Retained pages subscribe. Avatar seeds use account-scoped identity cache keys. Public MomentAuthor/comment snapshots are never overwritten with local remarks. Group member actions and invitation IDs remain unchanged. Profile preview entry visibility and permission refresh remain server-controlled.

Red evidence:
- `flutter test --no-pub test/features/moments/moment_identity_consumers_test.dart --reporter compact`: exit 1, missing WeChatMomentTile `identityCache` named argument before implementation (clean isolated test import).
- Later group expansion: `flutter test --no-pub test/features/moments/moment_identity_consumers_test.dart --plain-name "retained group member search" --reporter expanded`: exit 1, expected `Group remark`, found 0, before group implementation.

Green evidence:
- Consumers + detail + profile privacy + identity refresh + `test/features/contacts`: 72 passed.
- Consumers + Moments flow: 18 passed (4 consumer tests at that stage).
- Consumers + group info + group member profile: 22 passed (5 consumer tests). Coverage includes open reply header rename, retained search → friend profile → back update, personal title update, tile author/like/reply rename and custom-avatar clear, retained group search rename/avatar.
- Flutter analysis across 9 initial UI files: no issues. Expanded group files: no issues. Final analysis of group info/address + Moments feed + consumer tests: no issues.
- Formatting applied to owned files.

The old flow fixture expected a remark inside server `display_name` to override a supplied public `nickname` without a local contact entry. The expectation now verifies `Bob`, matching centralized nickname precedence and preventing server-projected private remarks from becoming authoritative local state.

Figma: no remote Figma edit performed or claimed by this agent. Root agent maintains truthful export/registry and repository verification records. Known affected canonical pages: Contacts node 19:3, Moments node 19:4, Messages node 18:7. Contacts URL: https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-3 ; Moments URL: https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-4 . No new node IDs, tokens, or geometry changes.

Root owns remaining composition-root wiring, whole-repository verification, contract checks, and cross-agent final review. These are not represented as completed here.

## Quality review follow-up

Read-only media review found an original-photo preview allocation issue in the comment composer: Image.memory rendered at 48 logical pixels but decoded the full original. Root explicitly assigned the preview and its tests for remediation. The shared `boundedChatImageProvider` now caps both decoded axes to ceil(48 × devicePixelRatio), bounded to 48–192 physical pixels, with ResizeImagePolicy.fit. Original selected/upload bytes and GIF animation bytes remain untouched.

Red: two DPR 2/5 preview tests failed because the original provider was MemoryImage rather than ResizeImage. Green: all 9 moment_comment_composer tests passed; the composer and test analyzer reported no issues.

Full-suite follow-up reproduced three obsolete assertions (username-based avatar seed, owner fallback seed, and server snapshot display_name overriding nickname). The avatar identity test now compares an actual feed tile and FriendIdentityCard injected with the same repository. The owner assertion compares the resolver account-scoped key; the privacy assertion requires Alice rather than a remark leaked into snapshot display_name. No app behavior change was needed for these test corrections. All 18 tests across moment_avatar_identity_test, wechat_moment_interactions_test, and moments_flow_test passed; analysis of these three files found no issues.

Media quality/security review additionally checked account snapshots before/after async stages, cancellation/disposal guards, retained completed uploads and comment idempotency keys on retry, GIF container/canvas/frame limits, MIME sniffing and independent business-vs-Matrix upload gateways. No other confirmed blocker was found. The shared built-in Unicode catalogs remain identical; deletion continues through the existing system keyboard. No separate backspace feature or encrypted favorite copying is required by the root's clarified scope. Device memory stress was not performed.

Backend-contract verification for the obsolete display_name fixture: `services/business-api/app/modules/moments/service.py` `_user_projection` (lines 449–470) returns `display_name = nickname or username` and explicitly never reads viewer ContactProfile remarks. `tests/business_api/moments/test_moments_api.py::test_identity_projection_is_remark_free` seeds differing private remarks then asserts public Alice/Bob names in feed/comments/likes/notifications. Therefore the synthetic snapshot with nickname Alice but display_name 项目小爱 does not represent the current backend contract. Current local repository remarks remain authoritative; there was no additional fallback implementation change.
