import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/member_directory_service.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/profile_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_controller.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/features/search/global_search_page.dart';
import 'package:liuhetong_mobile/features/settings/notification/notification_settings_page.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_controller.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_sheet.dart';
import 'package:liuhetong_mobile/ui/chat/chat_forward_picker_page.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';
import 'package:liuhetong_mobile/ui/components/wechat_gradient_divider.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';
import 'package:liuhetong_mobile/ui/notification/conversation_notification_mode_tile.dart';
import 'package:liuhetong_mobile/ui/theme/wechat_theme.dart';

/// 需求 §19 收尾（2026-09-19）：把上一轮遗漏的列表/卡片实心分割线全部换成
/// 共享 `WeChatGradientDivider`，并锁死深色解析。
///
/// 覆盖面：个人主页菜单行、通知设置分区卡片与设置行、点钻转账详情卡片的行、
/// 聊天记录搜索（结果行 / 分类行 / 群成员选择行）、会话通知三态行、全局搜索
/// 会话命中行、转发选择页的分区线、红包领取明细行。
///
/// 关键回归：`chat_transfer_detail_sheet.dart` 原先直接使用未解析的浅色常量
/// `WeChatColors.divider`（#D9D9D9）画 `Border(top:)`，深色模式下在
/// `darkElevated`（#232323）卡片上画出浅灰线。共享组件在 build 时按主题解析，
/// 本文件用「深色下中段色 == darkDivider」的断言锁死该行为。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('个人主页菜单行', () {
    testWidgets('菜单行分隔线改用共享渐隐分割线，行高与整行宽不变', (tester) async {
      await _pumpProfileHome(tester);

      final dividers = find.byKey(const Key('profile-menu-divider'));
      expect(dividers, findsNWidgets(5),
          reason: '个人主页 5 个菜单行都必须由共享渐隐分割线画行底分隔线');
      expect(tester.widgetList(dividers), everyElement(isA<WeChatGradientDivider>()));

      final gradient = _gradient(tester, dividers.first);
      _expectSharedGeometry(gradient);
      _expectLightSource(gradient);

      // 行内不得再留实心底边（第二套实现）。
      final tile = find.byKey(const Key('profile-details-entry'));
      expect(_rowDecoration(tester, tile).border, isNull,
          reason: '个人主页菜单行不得再画实心 Border(bottom:)');
      // 行高不因画线改变（原先 height: 57）。
      expect(tester.getSize(tile).height, 57);
      // 分隔线整行宽（原位无缩进）。
      expect(_lineRect(tester, dividers.first).left,
          tester.getRect(tile).left,
          reason: '个人主页菜单行分隔线保持整行宽，不引入缩进');
    });

    testWidgets('深色下菜单行分隔线按 darkDivider 解析', (tester) async {
      await _pumpProfileHome(tester, brightness: Brightness.dark);

      _expectDarkSource(
          _gradient(tester, find.byKey(const Key('profile-menu-divider')).first));
    });
  });

  group('通知设置', () {
    testWidgets('分区卡片上下边线与设置行分隔线改用共享渐隐分割线', (tester) async {
      await tester.pumpWidget(const CupertinoApp(home: NotificationSettingsPage()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      for (final title in const [
        notificationSettingsNewMessagesSection,
        notificationSettingsImportantSection,
      ]) {
        for (final edge in const ['top', 'bottom']) {
          final finder =
              find.byKey(Key('notification-settings-divider-$edge-$title'));
          expect(finder, findsOneWidget, reason: '$title 分区 $edge 边线必须存在');
          expect(tester.widget(finder), isA<WeChatGradientDivider>(),
              reason: '$title 分区 $edge 边线必须使用共享渐隐分割线');
          _expectSharedGeometry(_gradient(tester, finder));
        }
        final card =
            tester.widget<Container>(find.byKey(Key('notification-section-$title')));
        expect((card.decoration as BoxDecoration?)?.border, isNull,
            reason: '$title 分区卡片不得再画实心上下边框');
      }

      // 分区内的设置行同样走共享组件（保留左缩进 16dp）。
      expect(find.byKey(const Key('settings-row-divider')), findsWidgets);
    });

    testWidgets('设置行分隔线保留 16dp 左缩进且行高不因画线改变', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 320,
            child: WeChatSettingsRow(label: '消息通知'),
          ),
        ),
      ));

      final divider = find.byKey(const Key('settings-row-divider'));
      expect(tester.widget(divider), isA<WeChatGradientDivider>());
      expect(tester.widget<WeChatGradientDivider>(divider).indent,
          WeChatSpacing.lg,
          reason: '设置行原本 margin-left 16dp，必须由共享组件的 indent 承担');
      expect(
          _lineRect(tester, divider).left, 16,
          reason: '设置行分隔线的 16dp 左缩进必须与改造前一致');
      _expectSharedGeometry(_gradient(tester, divider));
    });

    testWidgets('深色下设置行分隔线按 darkDivider 解析', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.dark),
        home: const Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 320, child: WeChatSettingsRow(label: '消息通知')),
        ),
      ));

      _expectDarkSource(
          _gradient(tester, find.byKey(const Key('settings-row-divider'))));
    });
  });

  group('点钻转账详情卡片', () {
    testWidgets('明细行与账单ID行改用共享渐隐分割线', (tester) async {
      final gateway = _TransferGateway(_transferDetail(billId: 'ledger-1'));
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: ChatTransferDetailSheet(
          gateway: gateway,
          transferId: 'transfer-1',
          viewerId: 'receiver-1',
        ),
      ));
      addTearDown(gateway.dispose);
      await tester.pump();

      final rows = find.byKey(const Key('chat-transfer-detail-row-divider'));
      expect(rows, findsNWidgets(3),
          reason: '4 条明细行之间 3 条分隔线，必须来自共享组件');
      expect(tester.widgetList(rows), everyElement(isA<WeChatGradientDivider>()));
      final copy =
          find.byKey(const Key('chat-transfer-detail-copy-bill-divider'));
      expect(copy, findsOneWidget);
      expect(tester.widget(copy), isA<WeChatGradientDivider>());
      _expectSharedGeometry(_gradient(tester, rows.first));
      _expectLightSource(_gradient(tester, copy));

      expect(find.byKey(const Key('chat-transfer-receipt-detail-card')),
          findsOneWidget);
    });

    testWidgets('深色下明细行分隔线不再画浅灰实心线（回归）', (tester) async {
      final gateway = _TransferGateway(_transferDetail(billId: 'ledger-1'));
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.dark),
        home: ChatTransferDetailSheet(
          gateway: gateway,
          transferId: 'transfer-1',
          viewerId: 'receiver-1',
        ),
      ));
      addTearDown(gateway.dispose);
      await tester.pump();

      // 旧实现直接使用未解析的 WeChatColors.divider = #D9D9D9，深色下画出
      // 浅灰线（217）；共享组件必须解析为 darkDivider = #2C2C2C（44）。
      final gradient = _gradient(
          tester, find.byKey(const Key('chat-transfer-detail-row-divider')).first);
      _expectDarkSource(gradient);
      _expectSharedGeometry(gradient);

      final copyGradient = _gradient(
          tester, find.byKey(const Key('chat-transfer-detail-copy-bill-divider')));
      _expectDarkSource(copyGradient);

      // 整张卡片内不得残留任何实心 border 的浅色线。
      for (final box in tester.widgetList<Container>(find.descendant(
          of: find.byKey(const Key('chat-transfer-receipt-detail-card')),
          matching: find.byType(Container)))) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration) {
          expect(decoration.border, isNull,
              reason: '转账详情卡片内不得再自拼实心分割线');
        }
      }
    });
  });

  group('聊天记录搜索', () {
    testWidgets('结果行改用共享渐隐分割线', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: ChatSearchPage(
          isGroup: false,
          search: (f, {cursor, limit = 50}) async => [_message('e1', 'Hello')],
          memberEntries: const [],
          onJumpToMessage: (_) {},
        ),
      ));
      await tester.enterText(
          find.byKey(const Key('chat-search-input')), 'hello');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      final row = find.byKey(const Key('chat-search-result-e1'));
      expect(row, findsOneWidget);
      final divider =
          find.byKey(const Key('chat-search-result-row-divider'));
      expect(divider, findsOneWidget);
      expect(tester.widget(divider), isA<WeChatGradientDivider>());
      _expectSharedGeometry(_gradient(tester, divider));
      expect(_rowDecoration(tester, row).border, isNull,
          reason: '搜索结果行不得再画实心 Border(bottom:)');
    });

    testWidgets('分类行（文件/链接）改用共享渐隐分割线', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: ChatCategoryPage(
          title: '文件',
          category: ChatSearchMediaCategory.file,
          messages: [_message('e1', 'a.pdf'), _message('e2', 'b.pdf')],
          onOpen: (_) {},
        ),
      ));
      await tester.pump();

      final divider = find.byKey(const Key('chat-search-category-row-divider'));
      expect(divider, findsWidgets);
      expect(tester.widgetList(divider),
          everyElement(isA<WeChatGradientDivider>()));
      _expectSharedGeometry(_gradient(tester, divider.first));
      // 行内不得再留自拼的实心线（改造后整行没有 Container 装饰）。
      expect(
          find.descendant(
              of: find.byKey(const Key('category-file-e1')),
              matching: find.byType(Container)),
          findsNothing);
    });

    testWidgets('群成员选择行改用共享渐隐分割线并保留深色解析', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.dark),
        home: MemberPickerPage(entries: const [
          MemberDirectoryEntry(userId: 'u1', nickname: 'A'),
          MemberDirectoryEntry(userId: 'u2', nickname: 'B'),
        ]),
      ));
      await tester.pump();

      final divider = find.byKey(const Key('chat-search-member-row-divider'));
      expect(divider, findsWidgets);
      expect(tester.widgetList(divider),
          everyElement(isA<WeChatGradientDivider>()));
      _expectDarkSource(_gradient(tester, divider.first));
      expect(
          _rowDecoration(tester, find.byKey(const Key('member-picker-u1')))
              .border,
          isNull);
    });
  });

  group('§19 复扫补漏', () {
    testWidgets('会话通知三态行的分隔线改用共享组件并保留 16dp 缩进', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: ConversationNotificationModeTile(
          muted: false,
          attention: false,
          onChanged: (_) {},
        ),
      ));

      final divider = find.byKey(const Key('notification-mode-row-divider'));
      expect(divider, findsNWidgets(2));
      expect(tester.widgetList(divider),
          everyElement(isA<WeChatGradientDivider>()));
      // 视图内原有左边距：容器 padding 16 + 行内 margin 16 = 32。
      expect(_lineRect(tester, divider.first).left, 32);
      _expectSharedGeometry(_gradient(tester, divider.first));
    });

    testWidgets('转发选择页的分区线改用共享组件', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: ChatForwardPickerPage(
          candidates: [
            ChatForwardCandidate(
                roomId: 'r1',
                title: 'A',
                avatar: const SizedBox.shrink()),
            ChatForwardCandidate(
                roomId: 'r2',
                title: 'B',
                avatar: const SizedBox.shrink()),
          ],
          recentRoomIds: const ['r1'],
          onForward: (_) async {},
        ),
      ));
      await tester.pump();

      final divider = find.byKey(const Key('forward-picker-section-divider'));
      expect(divider, findsOneWidget);
      expect(tester.widget(divider), isA<WeChatGradientDivider>());
      _expectSharedGeometry(_gradient(tester, divider));
    });

    testWidgets('全局搜索会话命中行改用共享组件并保留 62dp 缩进', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: GlobalSearchConversationRecordsPage(
          conversation: GlobalSearchConversationHit(
            roomId: '!r:test',
            roomName: 'Room',
            isGroup: true,
            hits: [
              _hit('e1', 'Hello'),
              _hit('e2', 'World'),
            ],
          ),
          query: 'hello',
          onOpenHit: (_) async {},
        ),
      ));
      await tester.pump();

      final divider = find.descendant(
          of: find.byKey(const Key('global-search-conversation-records')),
          matching: find.byType(WeChatGradientDivider));
      expect(divider, findsOneWidget,
          reason: '两条命中之间必须由共享渐隐分割线分隔');
      expect(_lineRect(tester, divider).left, 62,
          reason: '全局搜索命中行原本 margin-left 62dp，必须由 indent 承担');
      // 旧实现直接使用未解析的 WeChatColors.divider，深色下是浅灰线。
      _expectLightSource(_gradient(tester, divider));
      // 命中行不得再自拼实心线。
      for (final box in tester.widgetList<Container>(find.descendant(
          of: find.byKey(const Key('global-search-conversation-records')),
          matching: find.byType(Container)))) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration) {
          expect(decoration.border, isNull);
        }
      }
    });

    testWidgets('红包领取明细行改用共享组件并保留 62dp 缩进', (tester) async {
      // 领取明细卡片在长页面下方，放大视口让懒加载列表把明细行建出来。
      await tester.binding.setSurfaceSize(const Size(800, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(CupertinoApp(
        theme: WeChatTheme.build(Brightness.light),
        home: RedPacketClaimDetailPage(
          api: _RedPacketGateway(),
          packetId: 'packet-1',
        ),
      ));
      await tester.pump();

      final divider = find.descendant(
          of: find.byKey(const Key('red-packet-claim-records')),
          matching: find.byType(WeChatGradientDivider));
      expect(divider, findsNWidgets(2),
          reason: '3 条领取记录之间 2 条分隔线，必须来自共享组件');
      final card = tester.getRect(find.byKey(const Key('red-packet-claim-records')));
      for (var i = 0; i < 2; i++) {
        // 卡片自身左外边距 12dp + 原行内 62dp 缩进。
        expect(_lineRect(tester, divider.at(i)).left - card.left, 62,
            reason: '领取明细行原本 margin-left 62dp，必须由 indent 承担');
        _expectSharedGeometry(_gradient(tester, divider.at(i)));
      }
    });
  });
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Future<void> _pumpProfileHome(WidgetTester tester,
    {Brightness brightness = Brightness.light}) async {
  final controller = ProfileController(
    gateway: _ProfileGateway(),
    avatarSource: _NoAvatarSource(),
  );
  addTearDown(controller.dispose);
  await controller.load();
  await tester.pumpWidget(CupertinoApp(
    theme: WeChatTheme.build(brightness),
    home: ProfileExperiencePage(
      controller: controller,
      onMoments: () {},
      onCaibi: () {},
      onWallet: () {},
      onInvite: () {},
      onSettings: () {},
    ),
  ));
  await tester.pump();
}

LinearGradient _gradient(WidgetTester tester, Finder divider) =>
    (tester
            .widget<DecoratedBox>(find.descendant(
                of: divider, matching: find.byType(DecoratedBox)))
            .decoration as BoxDecoration)
        .gradient! as LinearGradient;

/// 共享几何与不透明度：stops 0/0.18/0.82/1，两端 alpha 0、中段 alpha 0.5。
void _expectSharedGeometry(LinearGradient gradient) {
  expect(gradient.stops, const [
    WeChatDividerTokens.edgeStartStop,
    WeChatDividerTokens.coreStart,
    WeChatDividerTokens.coreEnd,
    WeChatDividerTokens.edgeEndStop,
  ]);
  expect(gradient.colors.first.a, WeChatDividerTokens.edgeAlpha);
  expect(gradient.colors.last.a, WeChatDividerTokens.edgeAlpha);
  expect(gradient.colors[1].a, WeChatDividerTokens.centerAlpha);
}

void _expectLightSource(LinearGradient gradient) {
  expect(gradient.colors[1].r, closeTo(217 / 255, 0.01),
      reason: '浅色色源必须是 divider token #D9D9D9');
  expect(gradient.colors[1].g, closeTo(217 / 255, 0.01));
  expect(gradient.colors[1].b, closeTo(217 / 255, 0.01));
}

void _expectDarkSource(LinearGradient gradient) {
  expect(gradient.colors[1].r, closeTo(44 / 255, 0.01),
      reason: '深色色源必须是 darkDivider #2C2C2C（不得残留浅色 #D9D9D9）');
  expect(gradient.colors[1].g, closeTo(44 / 255, 0.01));
  expect(gradient.colors[1].b, closeTo(44 / 255, 0.01));
}

/// 实际画线的矩形（`WeChatGradientDivider` 的 `indent` 由内层 `Padding` 承担，
/// 组件自身的矩形不含缩进）。
Rect _lineRect(WidgetTester tester, Finder divider) => tester.getRect(
    find.descendant(of: divider, matching: find.byType(DecoratedBox)));

BoxDecoration _rowDecoration(WidgetTester tester, Finder row) {
  final container = find
      .descendant(of: row, matching: find.byType(Container))
      .first;
  return tester.widget<Container>(container).decoration! as BoxDecoration;
}

ChatSearchMessage _message(String id, String text) => ChatSearchMessage(
      eventId: id,
      senderId: '@a:x',
      senderDisplayName: 'A',
      timestamp: DateTime(2026, 9, 6, 10, 30),
      timelineOrder: 1,
      visibleText: text,
      mediaCategory: ChatSearchMediaCategory.file,
      hasMedia: true,
    );

GlobalSearchMessageHit _hit(String id, String body) => GlobalSearchMessageHit(
      roomId: '!r:test',
      roomName: 'Room',
      isGroup: true,
      eventId: id,
      senderId: '@a:x',
      senderName: 'A',
      timestamp: DateTime(2026, 9, 6, 10, 30),
      body: body,
    );

const _profile = ProfileData(
  username: 'alice',
  nickname: 'Alice',
  maskedEmail: 'al***@example.test',
  fallbackSeed: 'seed',
  signature: 'hello',
);

final class _ProfileGateway implements ProfileGateway {
  @override
  Future<ProfileData> loadProfile() async => _profile;

  @override
  Future<ProfileData> updateProfile(
          {String? nickname,
          String? signature,
          String? nudgeSuffix}) async =>
      _profile.copyWith(nickname: nickname, signature: signature);

  @override
  Future<AvatarUploadSession> createAvatarUpload(
          {required String mimeType, required int byteSize}) async =>
      const AvatarUploadSession(uploadId: 'u', uploadUrl: '/u');

  @override
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate) async {}

  @override
  Future<ProfileData> completeAvatar(String uploadId) async => _profile;

  @override
  Future<void> cancelAvatar(String uploadId) async {}

  @override
  Future<void> deleteAvatar() async {}
}

final class _NoAvatarSource implements AvatarSource {
  @override
  Future<AvatarCandidate?> selectCropAndCompress() async => null;
}

Map<String, dynamic> _transferDetail({String? billId}) => {
      'id': 'transfer-1',
      'sender_id': 'sender-1',
      'receiver_id': 'receiver-1',
      'status': 'ACCEPTED',
      'amount': '200.00',
      'note': '午饭',
      'created_at': '2026-09-11T10:20:00Z',
      'accepted_at': '2026-09-11T10:21:00Z',
      if (billId != null) 'bill_id': billId,
    };

final class _TransferGateway implements ChatTransferDetailGateway {
  _TransferGateway(this.payload);

  final Map<String, dynamic> payload;
  final _invalidations = StreamController<void>.broadcast();

  @override
  int get sessionEpoch => 1;

  @override
  Stream<void> get sessionInvalidations => _invalidations.stream;

  @override
  Future<Map<String, dynamic>> detail(String transferId) async => payload;

  @override
  Future<Map<String, dynamic>> accept(String transferId) async => payload;

  @override
  Future<Map<String, dynamic>> decline(String transferId) async => payload;

  void dispose() => _invalidations.close();
}

final class _RedPacketGateway implements RedPacketViewGateway {
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async => {
        'id': 'packet-1',
        'sender_id': 'u-alice',
        'total': '88.00',
        'share_count': 3,
        'claimed_count': 3,
        'status': 'COMPLETED',
        'mode': 'RANDOM',
        'best_luck_eligible': true,
        'claims': [
          {
            'user_id': 'u-bob',
            'amount': '30.00',
            'claimed_at': '2026-08-29T10:00:00Z',
          },
          {
            'user_id': 'u-alice',
            'amount': '40.00',
            'claimed_at': '2026-08-29T10:01:00Z',
          },
          {
            'user_id': 'u-carol',
            'amount': '18.00',
            'claimed_at': '2026-08-29T10:02:00Z',
          },
        ],
      };

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async => {};

  @override
  Future<List<ContactSummary>> listContacts() async => const [];
}
