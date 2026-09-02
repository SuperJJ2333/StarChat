import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_presentation.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart'
    show changliaoCallMessageType;
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

void main() {
  test('direct title is remark then nickname with defensive fallbacks', () {
    expect(
      directConversationTitle(const ConversationIdentity(
        matrixUserId: '@alice:test',
        remark: '项目小艾',
        nickname: 'Alice',
        username: 'alice-login',
        matrixDisplayName: 'Matrix Alice',
      )),
      '项目小艾',
    );
    expect(
      directConversationTitle(const ConversationIdentity(
        matrixUserId: '@alice:test',
        nickname: 'Alice',
        username: 'alice-login',
      )),
      'Alice',
    );
    expect(
      directConversationTitle(const ConversationIdentity(
        matrixUserId: '@alice:test',
        username: 'alice-login',
      )),
      'alice-login',
    );
  });

  test('group title includes every member in supplied order', () {
    expect(
      groupConversationTitle(const [
        ConversationIdentity(
          matrixUserId: '@me:test',
          nickname: '我的昵称',
        ),
        ConversationIdentity(
          matrixUserId: '@alice:test',
          remark: '项目小艾',
          nickname: 'Alice',
        ),
        ConversationIdentity(
          matrixUserId: '@bob:test',
          nickname: 'Bob',
        ),
      ]),
      '我的昵称、项目小艾、Bob',
    );
  });

  test('sender resolution does not confuse username with nickname', () {
    expect(
      conversationSenderName(const ConversationIdentity(
        matrixUserId: '@alice:test',
        remark: '项目小艾',
        nickname: 'Alice',
        username: 'alice-login',
        matrixDisplayName: 'Matrix Alice',
      )),
      '项目小艾',
    );
    expect(
      conversationSenderName(const ConversationIdentity(
        matrixUserId: '@alice:test',
        nickname: 'Alice',
        username: 'alice-login',
        matrixDisplayName: 'Matrix Alice',
      )),
      'Alice',
    );
    expect(
      conversationSenderName(const ConversationIdentity(
        matrixUserId: '@alice:test',
        username: 'alice-login',
        matrixDisplayName: 'Matrix Alice',
      )),
      'alice-login',
      reason: '需求 #5：无备注/昵称时展示用户名（优先于 Matrix 展示名）',
    );
    expect(
      conversationSenderName(
        const ConversationIdentity(matrixUserId: '@alice:example.test'),
      ),
      'alice',
    );
  });

  test('group subtitle uses unread prefix and strict sender format', () {
    expect(
      groupConversationSubtitle(
        unreadCount: 3,
        senderName: '项目小李',
        messageContent: '消息内容',
      ),
      '[3条]项目小李：消息内容',
    );
    expect(
      groupConversationSubtitle(
        unreadCount: 0,
        senderName: '项目小李',
        messageContent: '消息内容',
      ),
      '项目小李：消息内容',
    );
  });

  test('group redaction keeps sender and omits the colon', () {
    expect(
      groupConversationSubtitle(
        unreadCount: 3,
        senderName: '项目小李',
        messageContent: '',
        redacted: true,
      ),
      '[3条]项目小李撤回了一条消息',
    );
  });

  test('true system event uses an explicit localized summary', () {
    expect(
      groupConversationSubtitle(
        unreadCount: 2,
        senderName: '',
        messageContent: '',
        systemSummary: '群聊名称已更新',
      ),
      '[2条]群聊名称已更新',
    );
  });

  test('undecrypted events use a safe placeholder instead of event text', () {
    expect(
      safeConversationMessageContent(
        undecrypted: true,
        messageContent: 'MegolmException secret ciphertext detail',
      ),
      '消息尚未解密',
    );
    expect(
      safeConversationMessageContent(
        undecrypted: false,
        messageContent: '正常消息',
      ),
      '正常消息',
    );
  });

  test('media bubbles render without the outer bubble underlay', () {
    // 语音/红包/转账/图片/视频自带完整视觉，外层气泡底衬会形成垫底冲突
    // （如白气泡垫绿语音、绿气泡套视频缩略图）。
    expect(messageBubbleIsDecorated(RoomMessageKind.voice), isFalse);
    expect(messageBubbleIsDecorated(RoomMessageKind.redPacket), isFalse);
    expect(messageBubbleIsDecorated(RoomMessageKind.transfer), isFalse);
    expect(messageBubbleIsDecorated(RoomMessageKind.image), isFalse,
        reason: '图片消息无气泡（微信式，缩略图即消息）');
    expect(messageBubbleIsDecorated(RoomMessageKind.video), isFalse,
        reason: '视频消息无气泡（微信式，缩略图即消息）');
    expect(messageBubbleIsDecorated(RoomMessageKind.text), isTrue);
    expect(messageBubbleIsDecorated(RoomMessageKind.file), isTrue);
  });

  test('media and call messages map to fixed summary labels', () {
    expect(
      conversationEventSummaryLabel(
          messageType: 'm.image', content: const {}),
      '[图片]',
    );
    expect(
      conversationEventSummaryLabel(
          messageType: 'm.video', content: const {}),
      '[视频]',
    );
    expect(
      conversationEventSummaryLabel(
          messageType: 'm.audio', content: const {}),
      '[语音]',
    );
    expect(
      conversationEventSummaryLabel(
          messageType: 'm.file', content: const {}),
      '[文件]',
    );
    expect(
      conversationEventSummaryLabel(
        messageType: changliaoCallMessageType,
        content: {'call_type': 'voice'},
      ),
      '[语音通话]',
    );
    expect(
      conversationEventSummaryLabel(
        messageType: changliaoCallMessageType,
        content: {'call_type': 'video'},
      ),
      '[视频通话]',
    );
    expect(
      conversationEventSummaryLabel(
          messageType: 'm.text', content: const {}),
      isNull,
      reason: '普通文本消息仍展示原文',
    );
  });
}
