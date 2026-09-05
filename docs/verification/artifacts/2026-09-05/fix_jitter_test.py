from pathlib import Path

p = Path('apps/mobile_flutter/test/features/matrix/call_page_test.dart')
raw = p.read_text(encoding='utf-8')

seg_old = """    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          autoCloseOnEnd: true,
        ),
      ),
    );
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();

    // 短暂 ended（网络抖动）：3 秒缓冲内不 pop。"""

seg_new = """    await tester.pumpWidget(const CupertinoApp(home: Placeholder()));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
      CupertinoPageRoute<void>(
        builder: (_) => CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          autoCloseOnEnd: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();

    // 短暂 ended（网络抖动）：3 秒缓冲内不 pop。"""

assert seg_old in raw, 'segment not found'
raw = raw.replace(seg_old, seg_new, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('OK')
