import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_conversation_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';

class AvatarRoom implements AvatarMediaCapability {
  final loading = Completer<List<MatrixMemberSnapshot>>();
  int requests = 0;
  List<MatrixMemberSnapshot> cached = [];
  MatrixConversationRoomSnapshot get snapshot => MatrixConversationRoomSnapshot(
        id: '!group:test',
        displayName: 'Group',
        avatar: null,
        isDirect: false,
        directPeerId: null,
        members: cached,
        lastEvent: null,
        preference: const ConversationPreference(),
        notificationCount: 0,
        notificationsEnabled: true,
      );
  Future<List<MatrixMemberSnapshot>> loadMembers() {
    requests++;
    return loading.future;
  }

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar(
          {required Uri? avatarUri, required double size}) async =>
      null;
}

void main() {
  testWidgets('cached members stay visible while loading and after failure',
      (tester) async {
    final room = AvatarRoom();
    room.cached = [
      const MatrixMemberSnapshot(
          id: '@cached:test', displayName: 'Cached', avatar: null)
    ];
    await tester.pumpWidget(CupertinoApp(
      home: Center(
          child: MatrixConversationAvatar(
              room: room.snapshot,
              avatarMedia: room,
              loadMembers: room.loadMembers)),
    ));
    expect(find.byType(GroupAvatarMosaic), findsOneWidget);
    expect(find.byType(MatrixUserAvatar), findsOneWidget);
    room.loading.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.byType(MatrixUserAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late member completion after closing the picker is safe',
      (tester) async {
    final room = AvatarRoom();
    await tester.pumpWidget(CupertinoApp(
      home: Center(
          child: MatrixConversationAvatar(
              room: room.snapshot,
              avatarMedia: room,
              loadMembers: room.loadMembers)),
    ));
    await tester.pumpWidget(const SizedBox());
    room.loading.complete([]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty cached group loads real members into a visible mosaic',
      (tester) async {
    final room = AvatarRoom();
    await tester.pumpWidget(CupertinoApp(
      home: Center(
          child: MatrixConversationAvatar(
              room: room.snapshot,
              avatarMedia: room,
              loadMembers: room.loadMembers,
              size: 52)),
    ));
    expect(room.requests, 1);
    expect(find.byIcon(CupertinoIcons.person_2_fill), findsOneWidget);
    final alice = MatrixMemberSnapshot(
        id: '@alice:test', displayName: 'Alice', avatar: null);
    final bob =
        MatrixMemberSnapshot(id: '@bob:test', displayName: 'Bob', avatar: null);
    room.loading.complete([alice, bob]);
    await tester.pumpAndSettle();
    expect(find.byType(GroupAvatarMosaic), findsOneWidget);
    expect(find.byType(MatrixUserAvatar), findsNWidgets(2));
    expect(
        tester
            .widgetList<MatrixUserAvatar>(find.byType(MatrixUserAvatar))
            .map((avatar) => avatar.fallbackSeed),
        ['@alice:test', '@bob:test']);
    expect(room.requests, 1);
  });

  testWidgets('member loading failure keeps a visible group fallback',
      (tester) async {
    final room = AvatarRoom();
    await tester.pumpWidget(CupertinoApp(
      home: Center(
          child: MatrixConversationAvatar(
              room: room.snapshot,
              avatarMedia: room,
              loadMembers: room.loadMembers)),
    ));
    room.loading.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.person_2_fill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
