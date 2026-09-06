import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_conversation_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/chat/group_avatar_mosaic.dart';

class AvatarRoom extends Room {
  AvatarRoom() : super(id: '!group:test', client: Client('avatar-test'));
  final loading = Completer<List<User>>();
  int requests = 0;

  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [Membership.join],
    bool suppressWarning = false,
    bool cache = true,
  ]) {
    requests++;
    return loading.future;
  }
}

void main() {
  testWidgets('cached members stay visible while loading and after failure',
      (tester) async {
    final room = AvatarRoom();
    room.setState(User('@cached:test',
        room: room, displayName: 'Cached', membership: 'join'));
    await tester.pumpWidget(CupertinoApp(
      home: Center(child: MatrixConversationAvatar(room: room)),
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
      home: Center(child: MatrixConversationAvatar(room: room)),
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
      home: Center(child: MatrixConversationAvatar(room: room, size: 52)),
    ));
    expect(room.requests, 1);
    expect(find.byIcon(CupertinoIcons.person_2_fill), findsOneWidget);
    final alice = User('@alice:test',
        room: room, displayName: 'Alice', membership: 'join');
    final bob =
        User('@bob:test', room: room, displayName: 'Bob', membership: 'join');
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
      home: Center(child: MatrixConversationAvatar(room: room)),
    ));
    room.loading.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.byIcon(CupertinoIcons.person_2_fill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
