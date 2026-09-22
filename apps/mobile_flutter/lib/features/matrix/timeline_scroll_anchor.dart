import 'package:flutter/widgets.dart';
import '../../ui/chat/message_scroll_locator.dart';

/// A reverse lazy timeline whose overlapping windows retain their painted rows.
///
/// Replacing the newest half of a bounded ListView changes the pixel origin.
/// Seeking back after paint exposes unrelated rows for several frames. Instead,
/// use a currently visible retained row as the center of two slivers and rebase
/// its scroll coordinate before layout. Only the bounded window is built; no
/// height estimates, post-frame jumps, or gesture cancellation are required.
///
/// [eventIds] are newest first. With a center sliver the newest edge can be
/// negative: callers must use minScrollExtent/extentBefore rather than zero.
class AnchoredTimelineList extends StatefulWidget {
  const AnchoredTimelineList({
    super.key,
    required this.controller,
    required this.eventIds,
    required this.messageKeys,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.followLatest = true,
  });

  final ScrollController controller;
  final List<String> eventIds;
  final Map<String, GlobalKey> messageKeys;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;

  /// Only enable for the live window, excluding explicit window transitions.
  final bool followLatest;

  @override
  State<AnchoredTimelineList> createState() => _AnchoredTimelineListState();
}

class _AnchoredTimelineListState extends State<AnchoredTimelineList> {
  final _viewportKey = GlobalKey();
  String? _centerId;
  bool _followLatestBeforePaint = false;

  bool _takeLatestFollow() {
    final result = _followLatestBeforePaint;
    _followLatestBeforePaint = false;
    return result;
  }

  @override
  void initState() {
    super.initState();
    _centerId = widget.eventIds.firstOrNull;
  }

  @override
  void didUpdateWidget(covariant AnchoredTimelineList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.followLatest &&
        widget.controller.hasClients &&
        oldWidget.eventIds.firstOrNull != widget.eventIds.firstOrNull) {
      final position = widget.controller.position;
      if (position.hasContentDimensions &&
          position.extentBefore < .5 &&
          !position.isScrollingNotifier.value) {
        // Keep the original sliver and its existing row elements. Changing the
        // center for each new message reparents every bubble and forces its
        // inherited dependencies to rebuild. Physics applies the new minimum
        // during layout, before paint, after new row heights are known.
        _followLatestBeforePaint = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _followLatestBeforePaint = false;
        });
      }
    }
    // Ordinary edits and prepending older rows do not move the coordinate
    // origin. Appending newer rows also preserves it while reading history.
    if (_centerId != null && widget.eventIds.contains(_centerId)) {
      final oldLeading = oldWidget.eventIds.firstOrNull == _centerId
          ? oldWidget.padding.bottom
          : 0.0;
      final newLeading = widget.eventIds.firstOrNull == _centerId
          ? widget.padding.bottom
          : 0.0;
      if (oldLeading != newLeading && widget.controller.hasClients) {
        final position = widget.controller.position;
        position.correctPixels(position.pixels + newLeading - oldLeading);
      }
      return;
    }
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is RenderBox &&
        viewport.hasSize &&
        widget.controller.hasClients) {
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      for (final id in widget.eventIds) {
        final box = widget.messageKeys[id]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (!rect.overlaps(bounds)) continue;
        _centerId = id;
        // In reverse layout the center row's bottom is the sliver origin.
        // correctPixels is a coordinate change, not a new scroll activity: an
        // incoming drag remains active and cannot cancel a half-finished seek.
        final leadingPadding =
            widget.eventIds.first == id ? widget.padding.bottom : 0.0;
        widget.controller.position
            .correctPixels(rect.bottom - bounds.bottom + leadingPadding);
        return;
      }
    }
    // A non-overlapping navigation (latest/date/search) has no retained anchor.
    // Start at its newest edge; explicit message locating remains the caller's
    // responsibility.
    _centerId = widget.eventIds.firstOrNull;
    if (widget.controller.hasClients) {
      widget.controller.position.correctPixels(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = widget.eventIds.indexOf(_centerId ?? '');
    final split = center < 0 ? 0 : center;
    final centerKey = ValueKey(('timeline-center', _centerId));
    Widget sliver({required bool before}) {
      final count = before ? split : widget.eventIds.length - split;
      int sourceIndex(int index) => before ? split - index - 1 : split + index;
      return SliverPadding(
        key: before ? ValueKey(('timeline-before', _centerId)) : centerKey,
        padding: EdgeInsets.only(
          left: widget.padding.left,
          right: widget.padding.right,
          top: before ? 0 : widget.padding.top,
          bottom: before || split == 0 ? widget.padding.bottom : 0,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => widget.itemBuilder(context, sourceIndex(index)),
            childCount: count,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = widget.eventIds.indexOf(key.value);
              if (index < 0 || (before ? index >= split : index < split)) {
                return null;
              }
              return before ? split - index - 1 : index - split;
            },
          ),
        ),
      );
    }

    return SizedBox(
      key: _viewportKey,
      child: CustomScrollView(
        controller: widget.controller,
        physics: _FollowTimelineLatestPhysics(takeFollow: _takeLatestFollow),
        reverse: true,
        center: centerKey,
        slivers: [if (split > 0) sliver(before: true), sliver(before: false)],
      ),
    );
  }
}

class _FollowTimelineLatestPhysics extends ScrollPhysics {
  const _FollowTimelineLatestPhysics({required this.takeFollow, super.parent});
  final bool Function() takeFollow;

  @override
  _FollowTimelineLatestPhysics applyTo(ScrollPhysics? ancestor) =>
      _FollowTimelineLatestPhysics(
          takeFollow: takeFollow, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (takeFollow() && !isScrolling) return newPosition.minScrollExtent;
    return super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity);
  }
}

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
    TimelineScrollAnchor? intersecting;
    for (final entry in keys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.overlaps(bounds)) {
        intersecting ??= TimelineScrollAnchor(entry.key, rect.top);
      }
      if (rect.top >= bounds.top && rect.top < bounds.bottom) {
        return TimelineScrollAnchor(entry.key, rect.top);
      }
    }
    return intersecting;
  }

  Future<void> restore(
      {required ScrollController controller,
      required Map<String, GlobalKey> keys,
      required List<String> eventIds,
      required bool Function() isMounted,
      bool Function()? canRestore}) async {
    bool active() => isMounted() && (canRestore?.call() ?? true);
    await WidgetsBinding.instance.endOfFrame;
    if (!active() || !controller.hasClients) return;
    var box = keys[eventId]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      await revealLazyMessage(
          controller: controller,
          eventIds: eventIds,
          messageKeys: keys,
          eventId: eventId,
          isMounted: isMounted,
          canContinue: canRestore);
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!active() || !controller.hasClients) return;
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
