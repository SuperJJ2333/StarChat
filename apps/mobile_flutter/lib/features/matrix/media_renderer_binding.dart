/// 渲染器-流绑定（审计 P1-3，gallery-call-review）。
///
/// 背景：此前 srcObject 只在 renderer 初始化完成与 controller 通知时
/// 赋值——若流在最近一次状态通知之后到达/重建（SDK onStreamAdd /
/// onStreamChanged / onStreamRemoved），画面会停留在 null/旧流。
/// 本类把"读当前流 → 写 renderer"的绑定收敛为可注入的纯逻辑单元：
/// - [update] 幂等：仅在流实例真正变化时写入（计时器 setState 不重绑）；
/// - 流后到/重建/移除均通过再次 [update] 收敛（由页订阅
///   `MatrixCallBackend.mediaStreamChanges` 驱动）；
/// - 页面销毁后调用 [dispose]，后续 update 变为空操作（防 dispose 竞争）；
/// - 泛型 [T]（生产为 MediaStream；测试可用任意替身，无需平台通道）。
final class MediaRendererBinding<T> {
  MediaRendererBinding({
    required this.readStream,
    required this.applyStream,
  });

  /// 当前应绑定的流（通常读 backend.localMediaStream/remoteMediaStream）。
  final T? Function() readStream;

  /// 写入渲染器（renderer.srcObject = stream）。
  final void Function(T? stream) applyStream;

  T? _last;
  bool _disposed = false;

  /// 当前已绑定的流实例（测试断言用）。
  T? get bound => _disposed ? null : _last;

  bool get isDisposed => _disposed;

  /// 幂等绑定：流实例未变化时不写入。
  void update() {
    if (_disposed) return;
    final stream = readStream();
    if (identical(stream, _last)) return;
    _last = stream;
    applyStream(stream);
  }

  /// 页面销毁后：解绑并使后续 update 空操作。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _last = null;
  }
}
