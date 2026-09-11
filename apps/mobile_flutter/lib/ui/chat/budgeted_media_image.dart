import 'package:flutter/widgets.dart';
import 'media_activity.dart';

final _sharedBudget = MediaAnimationBudget();

final class BudgetedMediaImage extends StatefulWidget {
  const BudgetedMediaImage(
      {super.key,
      required this.provider,
      required this.isAnimated,
      required this.visible,
      required this.priority,
      this.budget,
      this.width,
      this.height,
      this.fit,
      this.alignment = Alignment.center,
      this.gaplessPlayback = false,
      this.errorBuilder});
  final ImageProvider provider;
  final bool isAnimated, visible;
  final int priority;
  final MediaAnimationBudget? budget;
  final double? width, height;
  final BoxFit? fit;
  final Alignment alignment;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;
  @override
  State<BudgetedMediaImage> createState() => _BudgetedMediaImageState();
}

final class _BudgetedMediaImageState extends State<BudgetedMediaImage> {
  MediaActivityToken? _token;
  bool _hasBeenVisible = false;
  bool _grant = true;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant BudgetedMediaImage old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) _hasBeenVisible = false;
    if (old.budget != widget.budget || old.isAnimated != widget.isAnimated) {
      _bind();
    } else {
      _token?.update(priority: widget.priority, eligible: widget.visible);
    }
  }

  void _bind() {
    _token?.granted.removeListener(_changed);
    _token?.dispose();
    _token = null;
    _grant = !widget.isAnimated;
    if (widget.isAnimated) {
      _token = (widget.budget ?? _sharedBudget)
          .register(priority: widget.priority, eligible: widget.visible);
      _grant = false;
      _token!.granted.addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final token = _token;
      if (mounted && token != null) {
        setState(() => _grant = token.granted.value);
      }
    });
  }

  @override
  void dispose() {
    _token?.granted.removeListener(_changed);
    _token?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.visible) _hasBeenVisible = true;
    if (!widget.visible && !_hasBeenVisible) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    return TickerMode(
        enabled: widget.visible && (!widget.isAnimated || _grant),
        child: Image(
            key: ValueKey(widget.provider),
            image: widget.provider,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            alignment: widget.alignment,
            gaplessPlayback: widget.gaplessPlayback,
            errorBuilder: widget.errorBuilder));
  }
}
