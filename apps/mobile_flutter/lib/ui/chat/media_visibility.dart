import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

final class MediaVisibility extends StatefulWidget {
  const MediaVisibility(
      {super.key, required this.onChanged, required this.child});
  final ValueChanged<bool> onChanged;
  final Widget child;
  @override
  State<MediaVisibility> createState() => _MediaVisibilityState();
}

final class _MediaVisibilityState extends State<MediaVisibility>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool _scheduled = false;
  bool? _value;
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
    var visible = _active &&
        TickerMode.valuesOf(context).enabled &&
        (route?.isCurrent ?? true) &&
        box != null &&
        box.hasSize;
    if (visible) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final viewport = RenderAbstractViewport.maybeOf(box);
      final RenderBox? viewportBox =
          viewport is RenderBox ? viewport as RenderBox : null;
      final bounds = viewportBox == null
          ? Offset.zero & MediaQuery.sizeOf(context)
          : viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
      visible = rect.overlaps(bounds) &&
          rect.overlaps(Offset.zero & MediaQuery.sizeOf(context));
    }
    if (_value != visible) {
      _value = visible;
      widget.onChanged(visible);
    }
  }

  void _publish(bool value) {
    if (_value != value) {
      _value = value;
      widget.onChanged(value);
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
