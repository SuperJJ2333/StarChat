# Contacts & Friend and Conversation Operations Design

**Status:** Approved
**Date:** 2026-08-21
**Scope:** Flutter mobile contacts/friend workflow, friendship API authority, and message-list conversation operations.

## Goal

Deliver a WeChat-inspired Contacts & Friend experience that uses the repository's `UI_DESIGN.md` tokens and component rules, while keeping the business API authoritative for friendship state and Matrix limited to encrypted conversation-domain preferences.

## 1. Design system and accessibility

All screens target 393 × 852 logical pixels, use the existing `WeChatColors`, `WeChatSpacing`, `WeChatTypography`, and `WeChatDimensions` tokens, and support the product's light/dark themes. Root contact and message pages use `tabRootPageBackground`; list cells use `elevatedSurface`; ordinary list cells have no shadow. Touch targets are at least 44 × 44dp. Every icon-only control has a Chinese semantics label. Animations honour `MediaQuery.disableAnimations`.

## 2. Contacts & Friend information architecture

The Contacts tab has a 44dp navigation bar titled “通讯录” and a navigation action for “添加朋友”. The fixed top list order is: “新的朋友”, “群聊”, “标签”, and “官方客服”. The friend directory follows, grouped as starred friends, A–Z, then `#`; it retains the 20dp right index and its 64dp selected-letter feedback.

### 2.1 Add Friend

“添加朋友” provides a search field for username/畅聊号. A result cell shows a 48dp avatar, display name, 畅聊号, and one right-side state action:

- no relationship: “添加”; opens verification-message entry, then submits;
- outgoing request pending: disabled “申请已发送”; tapping reports “不能重复发送好友请求”;
- existing friendship: disabled “已添加”; tapping reports the same message;
- rejected/expired historical request: “重新申请”; submission reuses the original record.

The local state is only a responsiveness guard: it disables a currently in-flight button and renders the state returned by the API. The backend remains the authority and its duplicate error always maps to the exact Chinese toast text.

### 2.2 New Friends

The page uses a 44dp navigation bar titled “新的朋友” with the standard back affordance. Requests appear in a grouped, information-dense 68dp `WeChatFriendRequestTile`: 48dp avatar, nickname, optional two-line verification message, and a 64 × 32dp action/status at right. Pending incoming requests show “接受”; a contextual reject affordance appears on long press or in the row's secondary action while preserving a minimum 44dp hit target. Accepted rows show “已添加”, rejected rows “已拒绝”, and expired rows “已过期”. Each state has text and semantic label; color is supplementary only. Accept/reject updates the row in place and then refreshes the authoritative request list.

### 2.3 Friend profile, settings, tags, and groups

Friend profile continues the established hierarchy: 72dp identity header, display name, 畅聊号, signature, moments preview, and message/audio/video actions. “好友设置” retains the ordered rows: remark, tags, moments permission, blacklist, delete friend. Delete and block require confirmation. Tags use a 28dp light-gray chip and list/create/delete behaviors. “群聊” calls the existing public group-creation flow; contacts are never written through Matrix internals.

## 3. Friendship authority and duplicate prevention

`POST /api/v1/friends/requests` accepts `target_user_id` and optional `message` with an Idempotency-Key. In one business transaction it checks the pair in this order:

1. Same actor/target and nonexistent target produce their existing validation errors.
2. An existing friendship in either pair ordering produces `FRIEND_REQUEST_DUPLICATE` with HTTP 409 and message “不能重复发送好友请求”.
3. A pending outgoing request produces that same error.
4. The most recent outgoing request for the pair in `REJECTED` or `EXPIRED` is reused: keep its primary key, replace message and idempotency key, set status to `PENDING`, clear `resolved_at`, update `requested_at`, and audit/outbox the re-request.
5. With no reusable row, create a `PENDING` request.

The data model has `requested_at` (the latest submission timestamp) and retains `created_at` as immutable record creation time. A partial unique index/constraint prevents multiple pending outgoing rows per requester-target pair; the application check provides the user-facing error and the database provides race protection. Migration upgrade first adds the nullable timestamp, backfills it from `created_at`, then makes it non-null and adds the index. Downgrade reverses only this additive change.

The request-list endpoint returns all relevant received states needed by “新的朋友”, ordered by `requested_at` descending, and includes `requested_at`; it never exposes requester IDs. Search results return a relationship state projection (`NONE`, `OUTGOING_PENDING`, `FRIEND`, `REUSABLE`) derived from the business domain, not Matrix. OpenAPI documents the new field and stable duplicate code. Audit records and outbox events contain IDs and state transitions only, never verification-message text.

## 4. Message list long-press operations

Conversation state is local Matrix per-room account data (`com.liuhetong.conversation.settings.v2`). No message content, decrypted metadata, user identity, or financial state is transmitted to the business API.

Long-pressing any visible conversation shows a modal bottom action sheet with an `#80000000` scrim, 12dp top corners, 180ms fade/0.96→1 scale, icon and callout text rows, and outside-tap dismissal. The four operations are:

- **标记未读:** writes `manual_unread=true`. The tile displays a red unread dot; the count is a red dot because this is an explicit local marker. Opening the room clears the marker.
- **置顶该聊天 / 取消置顶:** toggles `pinned`; the false→true transition writes UTC `pinned_at`. Pinned conversations support multiple rooms and order by pin timestamp then room ID before ordinary conversations. Both direct and group rooms are eligible.
- **不显示该聊天:** writes `hidden=true` and records `hidden_at`. Hidden rooms are absent from the visible list but retain Matrix history. A newly observed incoming timeline event after `hidden_at` clears `hidden` and restores the room; own events do not restore it.
- **删除该聊天:** first shows a `WeChatDialog` titled “确定删除该聊天？”, with “取消” and a danger “删除”. Confirming calls the Matrix public room-history/local-state clear interface appropriate to the existing client, removes the room from visible list state, and never treats business API data as chat history. It does not affect other devices unless Matrix's room-leave/history semantics explicitly do so; the UI describes the actual selected behavior.

The operation sheet uses action labels and icon semantic labels. Tapping outside, Cancel, navigation back, or an operation completion closes it. Reduced-motion mode uses at most a 100ms fade.

## 5. Test and verification requirements

Backend tests cover same-key replay, changed-payload idempotency conflict, pending duplicate, friendship duplicate, rejected/expired reuse preserving ID and changing latest time, concurrent duplicate protection, and request/search projections. Flutter unit/widget tests cover request-state rendering, client duplicate error mapping, every new-friends state, row action transitions, Contacts fixed row order, conversation preference codec, manual unread clear-on-open, pin/unpin ordering, hidden restoration only for incoming newer events, bottom-sheet outside dismissal, and delete confirmation. Verification includes formatting, analysis/type checks, targeted tests, full Flutter tests, backend tests, `scripts/verify.ps1`, and documented evidence under `docs/verification/`.
