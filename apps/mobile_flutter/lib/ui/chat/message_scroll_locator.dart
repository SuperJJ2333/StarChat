import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// Reveals a loaded message in a reverse, newest-first lazy timeline.
/// Layout estimates are corrected from mounted neighbors after every seek.
Future<bool> revealLazyMessage({
  required ScrollController controller,
  required List<String> eventIds,
  required Map<String, GlobalKey> messageKeys,
  required String eventId,
  required bool Function() isMounted,
  bool Function()? canContinue,
}) async {
  bool active() => isMounted() && (canContinue?.call() ?? true);
  final targetIndex = eventIds.indexOf(eventId);
  if (targetIndex < 0) return false;
  final maximumAttempts = eventIds.length + 32;
  for (var attempt = 0; attempt < maximumAttempts; attempt++) {
    if (!active() ||
        !controller.hasClients ||
        controller.positions.length != 1) {
      return false;
    }
    final position = controller.position;
    if (!position.hasContentDimensions || position.viewportDimension <= 0) {
      await WidgetsBinding.instance.endOfFrame;
      continue;
    }
    final target = messageKeys[eventId]?.currentContext?.findRenderObject();
    if (target is RenderBox && target.attached && target.hasSize) {
      await position.ensureVisible(target, alignment: .5);
      await WidgetsBinding.instance.endOfFrame;
      if (!active() || !target.attached) return false;
      final viewport = RenderAbstractViewport.maybeOf(target);
      if (viewport == null) return false;
      final rect = MatrixUtils.transformRect(
          target.getTransformTo(viewport), target.paintBounds);
      if (rect.overlaps(viewport.paintBounds)) return true;
      continue;
    }

    var nearestIndex = -1;
    var nearestDistance = eventIds.length + 1;
    var totalHeight = 0.0;
    var mountedCount = 0;
    for (var index = 0; index < eventIds.length; index++) {
      final render =
          messageKeys[eventIds[index]]?.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final distance = (index - targetIndex).abs();
      if (distance < nearestDistance) {
        nearestIndex = index;
        nearestDistance = distance;
      }
      totalHeight += render.size.height;
      mountedCount++;
    }
    if (nearestIndex < 0 || mountedCount == 0) return false;
    final averageHeight = totalHeight / mountedCount;
    final direction = targetIndex > nearestIndex ? 1.0 : -1.0;
    // Keep normal rows on the established three-viewport bound. A measured
    // row taller than that bound gets a multi-row seek so it does not consume
    // one viewport-sized frame at a time.
    final maximumDistance = averageHeight > position.viewportDimension * 3
        ? averageHeight * 4
        : position.viewportDimension * 3;
    final distance = (nearestDistance * averageHeight)
        .clamp(position.viewportDimension / 2, maximumDistance);
    final next = (position.pixels + direction * distance)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (!active() || (next - position.pixels).abs() < .5) return false;
    controller.jumpTo(next);
    await WidgetsBinding.instance.endOfFrame;
  }
  return false;
}
