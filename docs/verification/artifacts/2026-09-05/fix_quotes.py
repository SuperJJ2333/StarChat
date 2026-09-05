from pathlib import Path

p = Path('apps/mobile_flutter/test/features/matrix/call_page_test.dart')
raw = p.read_text(encoding='utf-8')
raw = raw.replace('displayName: 周然,', "displayName: '周然',")
raw = raw.replace('fallbackSeed: alice,', "fallbackSeed: 'alice',")
raw = raw.replace(
    'expect(find.text(通话已结束), findsOneWidget);',
    "expect(find.text('通话已结束'), findsOneWidget);")
p.write_text(raw, encoding='utf-8', newline='')
print('fixed:', raw.count("'周然'"))
