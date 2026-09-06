# Friendship flow fixes implementation plan
Approved scope: user requested functional fixes and approved deferring Figma updates. Preserve existing work.
Goal: centered action labels; sender-derived default greeting; DEFAULT moments permission with independent hide switches and exclusive chat-only; incoming badges and audible popup; acceptance opens canonical encrypted room; requester sends original greeting once.
Architecture: business API remains authoritative for friendship/permissions; outgoing accepted request projection drives client-only encrypted Matrix message using stable transaction ID and account-scoped completed marker.
Files owned: Flutter request_friend_page.dart, add_friend_profile_page.dart, friend_request_review_page.dart, contacts_page.dart, friend_request_watch.dart, app_home.dart, focused tests and evidence.
- [x] Write failing widget and watcher tests.
- [x] Implement UI/watch fixes and shared acceptance navigation.
- [x] Focused tests, analyzer, specification then quality/security review; record evidence in docs/verification/artifacts/2026-09-05/friendship-deploy/.
- [ ] Parent integrates backend and deployment.
