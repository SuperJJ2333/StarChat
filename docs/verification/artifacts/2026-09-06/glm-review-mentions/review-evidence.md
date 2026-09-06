# GLM mention/member review evidence — 2026-09-06

Read-only production review. No production files modified.

Existing suite command (working directory apps/mobile_flutter):
flutter test --no-pub test/features/matrix/mention_composer_model_test.dart test/features/contacts/member_directory_service_test.dart test/ui/wechat_mention_panel_test.dart
Result: exit 0; 30 passed (15 composer + 8 directory + 7 panel).

Regression probe:
flutter test --no-pub D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-06/glm-review-mentions/mention_wiring_regression_test.dart
Result: exit 1; 3 failed for intended behavior:
- real listener typing @ opens mention trigger: expected 0, actual null.
- programmatic avatar mention retains recipient: expected [@brother:test], actual [].
- send snapshots recipients before clearing text: expected [@brother:test], actual [].

The probe uses real Flutter TextEditingController and copies the exact ordering of RoomPage's listener and mutation paths. It is NOT an end-to-end RoomPage widget test and does not require Matrix/network credentials. It demonstrates synchronous notification defects absent from the original pure model tests.

Code evidence:
- room_page.dart 276-303: triggerAt executes against old model text; new text assignment happens afterward.
- room_page.dart 340-364 and 1974-1984: model mutation precedes input.text synchronous notification, causing applyEdit to mutate fresh tokens again.
- room_page.dart 723-743: input.clear before recipientUserIds causes all mentions to be erased before send.
- mention_composer_model.dart 118: applyEdit unconditionally clears pendingTriggerStart, so continuing @ query loses selection context.
- member_directory_service.dart has only one production importer: ui/chat/wechat_mention_panel.dart.
- group_chat_info_page.dart 724-727: member search only lowercased display-name substring, no pinyin or shared sorting; 784-786 member removal retains snapshot ordering.
- conversation_presentation.dart 125-135: members follow preference/reconcileMemberOrder rather than alphabetical ordering.
- mention_composer_model.dart parseRecipientUserIdsFromHtml has no production callers.
