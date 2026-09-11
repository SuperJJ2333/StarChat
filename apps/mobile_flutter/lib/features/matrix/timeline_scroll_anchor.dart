import 'package:flutter/widgets.dart';
import '../../ui/chat/message_scroll_locator.dart';

/// Pixel position of an actually laid-out row, independent of estimated row
/// heights. Used only across explicit overlapping viewport changes.
final class TimelineScrollAnchor {
  TimelineScrollAnchor(this.eventId, this.globalY);
  final String eventId;
  final double globalY;
  static TimelineScrollAnchor? capture(
      Map<String, GlobalKey> keys, GlobalKey viewportKey) {
    final viewport = viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    for (final entry in keys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.top >= bounds.top && rect.top < bounds.bottom) {
        return TimelineScrollAnchor(entry.key, rect.top);
      }
    }
    return null;
  }

  Future<void> restore(
      {required ScrollController controller,
      required Map<String, GlobalKey> keys,
      required List<String> eventIds,
      required bool Function() isMounted}) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!isMounted() || !controller.hasClients) return;
    var box = keys[eventId]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      await revealLazyMessage(
          controller: controller,
          eventIds: eventIds,
          messageKeys: keys,
          eventId: eventId,
          isMounted: isMounted);
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!isMounted() || !controller.hasClients) return;
      box = keys[eventId]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final delta = globalY - box.localToGlobal(Offset.zero).dy;
      if (delta.abs() < .5) return;
      final position = controller.position;
      // Reversed timelines move rows downward as pixels increase.
      controller.jumpTo((position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
    }
  }
}
