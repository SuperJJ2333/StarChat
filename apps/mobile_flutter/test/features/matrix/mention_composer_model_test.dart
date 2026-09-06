import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

/// 规格 #3：修复重复 @（范围式 token 替换）。
void main() {
  group('替换触发范围（核心缺陷：不再追加双 @）', () {
    test('输入 @→选择"兄弟"：输入框为一个 @兄弟，无重复', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      final caret = model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test');
      expect(model.text, '@兄弟 ');
      expect(caret, 4);
      expect(model.recipientUserIds(), ['@brother:example.test']);
    });

    test('带查询片段：@兄 后选中 → @兄 被整体替换为 @兄弟', () {
      final model = MentionComposerModel(text: '叫一下@兄');
      model.triggerAt(3);
      expect(model.syncTrigger('叫一下@兄'), isTrue);
      model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test', cursor: 6);
      expect(model.text, '叫一下@兄弟 ', reason: '触发 @ 与查询字一并被替换');
    });

    test('句中选中（光标在句中）：仅替换触发片段，后文保留', () {
      final model = MentionComposerModel(text: '');
      model.text = '喂@快点来';
      model.triggerAt(1);
      model.replaceTrigger(
          displayName: '陈晨', userId: '@chen:example.test', cursor: 3);
      expect(model.text, '喂@陈晨 点来', reason: '@快 被 token 替换，"点来"保留');
    });

    test('连续选择两人：两个 token，互不重复', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test');
      // 第二个 @：文本现在是 "@兄弟 "，光标在末尾输入 @。
      model.text = '@兄弟 @';
      model.triggerAt(4);
      final caret = model.replaceTrigger(
          displayName: '陈晨', userId: '@chen:example.test');
      expect(model.text, '@兄弟 @陈晨 ');
      expect(caret, 8);
      expect(model.recipientUserIds(),
          containsAll(['@brother:example.test', '@chen:example.test']));
    });

    test('名称自带装饰性 @（@兄弟）：仅本次 token 规范化，无双 @@', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
          displayName: '@兄弟', userId: '@brother:example.test');
      expect(model.text, '@兄弟 ', reason: '名称开头 @ 被规范化，不产生 @@兄弟');
    });

    test('@所有人：token 固定"所有人"，收件为成员范围', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
        displayName: '所有人',
        userId: '@all',
        mentionAllUserIds: ['@a:example.test', '@b:example.test'],
      );
      expect(model.text, '@所有人 ');
      expect(model.recipientUserIds(),
          containsAll(['@a:example.test', '@b:example.test']));
    });
  });

  group('编辑同步（删除后不再提醒）', () {
    test('删除整个 token：发送不再提醒该用户', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test');
      // 删除 "@兄弟 "（0..4）。
      model.applyEdit(start: 0, removed: 4, inserted: 0);
      expect(model.tokens, isEmpty);
      expect(model.recipientUserIds(), isEmpty);
    });

    test('编辑 token 内部：token 失效', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test');
      // 在 token 中间插入一个字（"兄[插]弟"）。
      model.applyEdit(start: 2, removed: 0, inserted: 1);
      expect(model.tokens, isEmpty, reason: 'token 文本被改即失效');
    });

    test('token 之前插入文本：token 范围平移，仍有效', () {
      final model = MentionComposerModel(text: '');
      model.triggerAt(0);
      model.replaceTrigger(
          displayName: '兄弟', userId: '@brother:example.test');
      model.text = 'XX@兄弟 '; // 控制器已更新文本（头部加 2 字）。
      model.applyEdit(start: 0, removed: 0, inserted: 2);
      expect(model.tokens, hasLength(1));
      expect(model.tokens.single.start, 2);
      expect(model.recipientUserIds(), ['@brother:example.test']);
    });
  });

  group('历史富文本解析（仅合法用户链接）', () {
    test('合法提及 pill：识别目标 userId', () {
      const html =
          '<a href="https://matrix.to/#/@brother:example.test">@兄弟</a> 在吗';
      expect(MentionComposerModel.parseRecipientUserIdsFromHtml(html),
          ['@brother:example.test']);
    });

    test('@@兄弟 普通文本：不能推断收件人', () {
      const html = '@@兄弟 在吗';
      expect(MentionComposerModel.parseRecipientUserIdsFromHtml(html), isEmpty);
    });

    test('非提及 permalink（label 不以 @ 开头）：不计入', () {
      const html =
          '<a href="https://matrix.to/#/@brother:example.test">兄弟</a>';
      expect(MentionComposerModel.parseRecipientUserIdsFromHtml(html), isEmpty);
    });

    test('含多个 @ 的历史消息不崩溃', () {
      const html =
          '<a href="https://matrix.to/#/@a:example.test">@A</a> 和 <a href="https://matrix.to/#/@b:example.test">@B</a> @@plain';
      expect(MentionComposerModel.parseRecipientUserIdsFromHtml(html),
          containsAll(['@a:example.test', '@b:example.test']));
    });
  });

  group('触发状态机', () {
    test('触发字符被删除：面板应关闭', () {
      final model = MentionComposerModel(text: '@');
      model.triggerAt(0);
      expect(model.syncTrigger('x'), isFalse, reason: '@ 已不在原位置');
    });

    test('普通 @ 字符无触发记录：不弹面板（私聊场景调用方判 isGroup）', () {
      final model = MentionComposerModel(text: '邮箱 a@b.com');
      expect(model.syncTrigger('邮箱 a@b.com'), isFalse);
    });
  });
}
