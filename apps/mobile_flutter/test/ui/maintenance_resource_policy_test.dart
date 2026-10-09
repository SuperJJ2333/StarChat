import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/media_activity.dart';

void main() {
  test('release bundle excludes diagnostics and unused branding', () {
    final yaml = File('pubspec.yaml').readAsStringSync();
    expect(yaml, isNot(contains('    - assets/diagnostics/')));
    expect(yaml, isNot(contains('    - assets/emoji/\n')));
    expect(yaml, contains('    - assets/emoji/NOTICE.txt'));
    expect(yaml, contains('    - assets/emoji_vector/'));
    expect(File('assets/emoji/NOTICE.txt').readAsStringSync(),
        contains('MIT License'));
    expect(File('assets/branding/app_icon.png').existsSync(), true);
    expect(File('assets/diagnostics/video-h264.mp4').existsSync(), true);
    expect(yaml, isNot(contains('    - assets/branding/\n')));
  });
  test('default visible animation concurrency is bounded at four', () {
    final budget = MediaAnimationBudget();
    final tokens = List.generate(12, (_) => budget.register(priority: 1));
    expect(tokens.where((t) => t.granted.value), hasLength(4));
    for (final t in tokens) {
      t.dispose();
    }
  });
  test(
      'offline notice records personal-use boundary without animated MIT claim',
      () {
    final notice = File('assets/emoji/NOTICE.txt').readAsStringSync();
    expect(notice, contains('Personal Use Only'));
    expect(notice, contains('original downloaded commit is not established'));
    expect(
        notice,
        isNot(contains(
            'Animated Fluent Emojis (c) Tarikul-Islam-Anik, MIT License.')));
    final license = File('assets/emoji_vector/LICENSE.txt').readAsStringSync();
    expect(license, contains('Permission is hereby granted'));
    expect(
        sha256
            .convert(File('assets/emoji_vector/LICENSE.txt').readAsBytesSync())
            .toString(),
        'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383');
    expect(
        sha256
            .convert(File('assets/emoji/ANIMATED_SOURCE_LICENSE.txt')
                .readAsBytesSync())
            .toString(),
        '03aaf19c01575ca63371ac1ff80926f0e655138009f7d108dae593337a9824b0');
  });
}
