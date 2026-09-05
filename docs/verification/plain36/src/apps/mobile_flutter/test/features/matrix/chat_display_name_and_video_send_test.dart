import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_presentation.dart';
import 'package:liuhetong_mobile/features/matrix/video_transcode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveChatSenderDisplayName（需求 3 名称优先级）', () {
    test('私聊：有备注显示备注，无备注显示昵称', () {
      // 示例：原始昵称"一马当先"、备注"兄弟" → 私聊显示"兄弟"。
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: true,
          memberName: '一马当先',
          contactNickname: '一马当先',
          remark: '兄弟',
        ),
        '兄弟',
      );
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: true,
          memberName: '一马当先',
          contactNickname: '一马当先',
          remark: '',
        ),
        '一马当先',
      );
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: true,
          memberName: '一马当先',
          contactNickname: null,
          remark: null,
        ),
        '一马当先',
      );
    });

    test('群聊：群昵称 > 备注 > 昵称', () {
      // 群昵称"二马"（与全局昵称不同 → 视为显式设置）优先于备注。
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: false,
          memberName: '二马',
          contactNickname: '一马当先',
          remark: '兄弟',
        ),
        '二马',
      );
      // 未设群昵称（成员名 == 全局昵称）→ 显示备注"兄弟"。
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: false,
          memberName: '一马当先',
          contactNickname: '一马当先',
          remark: '兄弟',
        ),
        '兄弟',
      );
      // 备注也没有 → 显示原始昵称。
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: false,
          memberName: '一马当先',
          contactNickname: '一马当先',
          remark: null,
        ),
        '一马当先',
      );
      // 非好友（无昵称对照）：任何成员名视为群昵称生效。
      expect(
        resolveChatSenderDisplayName(
          isDirectChat: false,
          memberName: '路人甲',
          contactNickname: null,
          remark: null,
        ),
        '路人甲',
      );
    });
  });

  group('transcodeForChat（拍摄录像发送的压缩策略）', () {
    test('平台转码不可用时回退原始视频并给出明确提示', () async {
      // flutter test 环境无平台通道：VideoCompress 调用必然失败，
      // 策略必须回退原文件且携带 fallbackNotice（不静默）。
      final temp = File('${Directory.systemTemp.path}/chat-video-test-'
          '${DateTime.now().microsecondsSinceEpoch}.mp4');
      await temp.writeAsBytes(List<int>.filled(1024, 7), flush: true);
      try {
        var progressCalls = 0;
        final rendition = await transcodeForChat(
          temp,
          onProgress: (_) => progressCalls++,
        );
        expect(rendition.usedCompressed, isFalse);
        expect(rendition.fallbackNotice, contains('压缩版不可用'));
        expect(rendition.fallbackNotice, contains('原始视频'));
        expect(rendition.compressionRatio, isNull);
        expect(rendition.file.path, temp.path);
      } finally {
        await temp.delete();
      }
    });
  });
}
