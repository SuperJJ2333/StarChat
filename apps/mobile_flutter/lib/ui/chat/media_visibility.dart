import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// 媒体可见性窗口三态。
///
/// [warm] 表示「不在屏幕内、但在可见区域 ± [MediaVisibility.warmExtent]
/// 的前瞻范围内」——即在滚动容器 cacheExtent 内、即将进入屏幕的行。
/// 用于「只给可见 + 即将可见的媒体排后台任务」的门控。
enum MediaVisibilityWindow { hidden, warm, visible }

/// 媒体可见性检测（滚动 / 前台 / 路由 / TickerMode 四重条件）。
///
/// - [onChanged]：**严格可见**（与既有调用方语义完全一致）；
/// - [onWindowChanged]：三态窗口（可选）；传 null 时不做任何额外计算；
/// - [warmExtent]：可见区域上下各外扩的像素（默认 0 = 旧行为）。
///
/// [warmExtent] 只在存在滚动视口时生效（无滚动容器时 warm 等于 visible），
/// 且**不要求**元素在屏幕内——列表 cacheExtent 内被裁剪的行正是「即将
/// 进入区域」，必须能命中 warm。
final class MediaVisibility extends StatefulWidget {
  const MediaVisibility({
    super.key,
    required this.onChanged,
    required this.child,
    this.warmExtent = 0,
    this.onWindowChanged,
  });
  final ValueChanged<bool> onChanged;
  final Widget child;

  /// 可见区域上下各外扩的像素（±buffer）。0 表示只报严格可见。
  final double warmExtent;

  /// 三态窗口回调；为 null 时完全不参与计算（零行为变化）。
  final ValueChanged<MediaVisibilityWindow>? onWindowChanged;

  @override
  State<MediaVisibility> createState() => _MediaVisibilityState();
}

final class _MediaVisibilityState extends State<MediaVisibility>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool _scheduled = false;
  bool? _value;
  MediaVisibilityWindow? _window;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _active = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bind());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  void _bind() {
    if (!mounted) return;
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(next, _position)) {
      _schedule();
      return;
    }
    _position?.removeListener(_schedule);
    _position = next;
    _position?.addListener(_schedule);
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _report();
    });
  }

  void _report() {
    final box = context.findRenderObject() as RenderBox?;
    final route = ModalRoute.of(context);
    final active = _active &&
        TickerMode.valuesOf(context).enabled &&
        (route?.isCurrent ?? true);
    var visible = active && box != null && box.hasSize;
    var warm = visible;
    if (visible) {
      final render = box;
      final rect = render.localToGlobal(Offset.zero) & render.size;
      final viewport = RenderAbstractViewport.maybeOf(render);
      final RenderBox? viewportBox =
          viewport is RenderBox ? viewport as RenderBox : null;
      final screen = Offset.zero & MediaQuery.sizeOf(context);
      final bounds = viewportBox == null
          ? screen
          : viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
      final onScreen = rect.overlaps(screen);
      // 严格可见：与既有语义逐字一致（视口内 + 屏幕内）。
      visible = onScreen && rect.overlaps(bounds);
      // 前瞻窗口：仅在有滚动视口时外扩；被裁剪的 cacheExtent 行也算 warm。
      final buffer = viewportBox == null || widget.warmExtent <= 0
          ? bounds
          : Rect.fromLTRB(bounds.left, bounds.top - widget.warmExtent,
              bounds.right, bounds.bottom + widget.warmExtent);
      warm = visible || rect.overlaps(buffer);
    }
    if (_value != visible) {
      _value = visible;
      widget.onChanged(visible);
    }
    final window = visible
        ? MediaVisibilityWindow.visible
        : warm
            ? MediaVisibilityWindow.warm
            : MediaVisibilityWindow.hidden;
    if (_window != window) {
      _window = window;
      widget.onWindowChanged?.call(window);
    }
  }

  void _publish(bool value) {
    if (_value != value) {
      _value = value;
      widget.onChanged(value);
    }
    final window =
        value ? MediaVisibilityWindow.visible : MediaVisibilityWindow.hidden;
    if (_window != window) {
      _window = window;
      widget.onWindowChanged?.call(window);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _publish(false);
    } else {
      _schedule();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position?.removeListener(_schedule);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MediaVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return widget.child;
  }
}
