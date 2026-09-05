import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_renderer_binding.dart';

/// 审计 P1-3（gallery-call-review）：媒体流绑定单元（泛型替身注入，
/// 无需平台通道）。
///
/// 验证流在初始化/状态通知**之后**到达或重建时，绑定仍能收敛：
/// - 流后到（先 null 后流）→ 绑定生效；
/// - 流重建（新实例，SDK onStreamChanged 语义）→ 换绑；
/// - 流移除（null）→ 解绑；
/// - 幂等：同一实例重复 update 不重复写 renderer；
/// - dispose 后 update 空操作（防销毁竞争）。
final class _FakeStream {
  const _FakeStream(this.id);
  final String id;
}

void main() {
  test('流后到：初始化时无流，事件到达后 update 绑定成功', () {
    _FakeStream? current;
    final applied = <_FakeStream?>[];
    final binding = MediaRendererBinding<_FakeStream>(
      readStream: () => current,
      applyStream: applied.add,
    );

    // 初始化完成时流尚未到达（onStreamAdd 晚于 renderer init）：
    // null→null 幂等，不产生写入（renderer 初始即 null）。
    binding.update();
    expect(applied, isEmpty, reason: '尚未有流时不写入');

    // 流事件到达（延迟语义）→ 重新 update 绑定。
    current = const _FakeStream('s1');
    binding.update();
    expect(identical(binding.bound, current), isTrue, reason: '后到流被绑定');
    expect(applied, hasLength(1));
  });

  test('流重建（新实例）：换绑新流；移除：解绑', () {
    _FakeStream? current = const _FakeStream('s1');
    final applied = <_FakeStream?>[];
    final binding = MediaRendererBinding<_FakeStream>(
      readStream: () => current,
      applyStream: applied.add,
    );
    binding.update();

    // SDK onStreamChanged：track 重挂产生新流实例。
    current = const _FakeStream('s2');
    binding.update();
    expect(identical(binding.bound, current), isTrue, reason: '重建流换绑');

    // 流移除（onStreamRemoved）。
    current = null;
    binding.update();
    expect(binding.bound, isNull, reason: '移除后解绑');
    expect(applied, hasLength(3));
  });

  test('幂等：同一实例重复 update 不重复写 renderer', () {
    const stream = _FakeStream('s1');
    var writes = 0;
    final binding = MediaRendererBinding<_FakeStream>(
      readStream: () => stream,
      applyStream: (_) => writes++,
    );
    binding.update();
    binding.update();
    binding.update();
    expect(writes, 1, reason: '计时器 setState / 重复事件不得反复赋值 srcObject');
  });

  test('dispose 后 update 空操作（页面销毁竞争防护）', () {
    _FakeStream? current = const _FakeStream('s1');
    var writes = 0;
    final binding = MediaRendererBinding<_FakeStream>(
      readStream: () => current,
      applyStream: (_) => writes++,
    );
    binding.update();
    binding.dispose();
    current = const _FakeStream('s2');
    binding.update();
    expect(writes, 1, reason: 'dispose 后不得再写已释放的 renderer');
    expect(binding.isDisposed, isTrue);
    expect(binding.bound, isNull);
  });
}
