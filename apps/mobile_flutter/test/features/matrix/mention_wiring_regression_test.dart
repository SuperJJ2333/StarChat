import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

/// GLM 审查 R1/R2/R3 回归：用真实 TextEditingController 驱动
/// RoomPage 同款事件顺序（最小复现，非完整 RoomPage E2E）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 复刻 RoomPage 的监听器接线（含 R1/R3 修复后的顺序与守卫）。
  late TextEditingController input;
  late MentionComposerModel mentionComposer;
  String lastComposerText = '';
  bool programmaticEdit = false;

  void handleComposerChanged() {
    if (programmaticEdit) return; // R3
    final next = input.text;
    if (next != lastComposerText) {
      final (start, removed, inserted) =
          MentionComposerModel.diffEdit(lastComposerText, next);
      mentionComposer.text = next; // R1：先更新文本。
      mentionComposer.applyEdit(start: start, removed: removed, inserted: inserted);
      final cursor = input.selection.baseOffset;
      if (inserted > 0 && cursor > 0 && cursor <= next.length) {
        final insertedEnd = start + inserted;
        if (insertedEnd == cursor && next.codeUnitAt(cursor - 1) == 0x40) {
          mentionComposer.triggerAt(cursor - 1);
        }
      }
      lastComposerText = next;
    }
  }

  void setComposerText(String text, int caret) {
    programmaticEdit = true;
    try {
      input.text = text;
      input.selection = TextSelection.collapsed(offset: caret);
      lastComposerText = text;
      mentionComposer.text = text;
    } finally {
      programmaticEdit = false;
    }
  }

  setUp(() {
    input = TextEditingController();
    mentionComposer = MentionComposerModel();
    lastComposerText = '';
    programmaticEdit = false;
    input.addListener(handleComposerChanged);
  });

  tearDown(() => input.dispose());

  group('R1：空框输入 @ 触发面板', () {
    test('空输入框输入 @ → pendingTriggerStart 非空', () {
      // 模拟真实键入：text 从 '' → '@'，光标在 1。
      input.value = const TextEditingValue(
        text: '@',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(mentionComposer.pendingTriggerStart, 0,
          reason: 'R1 修复前：triggerAt 检查旧 text（空串越界）→ null');
    });

    test('继续输入查询词（@兄）→ 触发范围保持', () {
      input.value = const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1));
      input.value = const TextEditingValue(
          text: '@兄', selection: TextSelection.collapsed(offset: 2));
      expect(mentionComposer.pendingTriggerStart, 0,
          reason: 'R1 修复前：applyEdit 无条件清除 trigger → 输入查询词丢失');
    });

    test('删除触发字符 → 触发清除', () {
      input.value = const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1));
      input.value = const TextEditingValue(
          text: '', selection: TextSelection.collapsed(offset: 0));
      expect(mentionComposer.pendingTriggerStart, isNull);
    });
  });

  group('R2：发送先清空不丢收件人', () {
    test('快照收件人 → 清空 → 收件人保留', () {
      // 正常选中一个提及。
      input.value = const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1));
      final caret = mentionComposer.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test', cursor: 1);
      setComposerText(mentionComposer.text, caret);

      // R2 修复：先快照收件人，再程序化清空。
      final mentions = mentionComposer.recipientUserIds();
      programmaticEdit = true;
      try {
        input.clear();
        lastComposerText = '';
        mentionComposer.text = '';
        mentionComposer.tokens.clear();
      } finally {
        programmaticEdit = false;
      }
      expect(mentions, ['@brother:example.test'],
          reason: 'R2 修复前：先 input.clear() 同步触发监听器清 token→快照为空');
    });
  });

  group('R3：程序插入不被监听器二次编辑', () {
    test('面板选中：_insertMention 同款顺序后 token 有效', () {
      input.value = const TextEditingValue(
          text: '@', selection: TextSelection.collapsed(offset: 1));
      // RoomPage._insertMention：replaceTrigger → _setComposerText。
      final caret = mentionComposer.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test', cursor: 1);
      setComposerText(mentionComposer.text, caret);

      expect(input.text, '@兄弟 ');
      expect(mentionComposer.recipientUserIds(), ['@brother:example.test'],
          reason: 'R3 修复前：监听器用旧 _lastComposerText 差分再次平移→token 失效');
    });

    test('长按头像快速 @（appendAtEnd）：token 保留', () {
      input.value = const TextEditingValue(text: '看看这条');
      final caret = mentionComposer.appendAtEnd(
          displayName: '陈晨', userId: '@chen:example.test');
      setComposerText(mentionComposer.text, caret);

      expect(input.text, '看看这条 @陈晨 ');
      expect(mentionComposer.recipientUserIds(), ['@chen:example.test']);
    });

    test('已有文本中间插入：token 范围正确', () {
      input.value = const TextEditingValue(
          text: '喂@', selection: TextSelection.collapsed(offset: 2));
      final caret = mentionComposer.replaceTrigger(
          displayName: 'Bob', userId: '@bob:example.test', cursor: 2);
      setComposerText(mentionComposer.text, caret);

      expect(input.text, '喂@Bob ');
      expect(mentionComposer.recipientUserIds(), ['@bob:example.test']);
    });
  });
}
