import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// Geometry shared by the overlay and edge-case tests. Coordinates are local
/// to the root overlay; the viewport excludes system and keyboard insets.
final class MessageMenuPlacement {
  const MessageMenuPlacement(this.rect, this.arrowAtTop, this.arrowX);
  final Rect rect;
  final bool arrowAtTop;
  final double arrowX;

  static MessageMenuPlacement calculate(
      {required Rect anchor,
      required Rect viewport,
      required Size menuSize,
      required bool outgoing}) {
    final width = math.min(menuSize.width, viewport.width);
    final height = math.min(menuSize.height, viewport.height);
    final below = anchor.bottom + 8;
    final above = anchor.top - height - 8;
    final arrowAtTop = below + height <= viewport.bottom ||
        (above < viewport.top &&
            viewport.bottom - anchor.bottom >= anchor.top - viewport.top);
    final top = (arrowAtTop ? below : above)
        .clamp(viewport.top, viewport.bottom - height)
        .toDouble();
    final left = (outgoing ? anchor.right - width : anchor.left)
        .clamp(viewport.left, viewport.right - width)
        .toDouble();
    final arrowX = (anchor.center.dx - left)
        .clamp(math.min(16, width / 2), math.max(width - 16, width / 2))
        .toDouble();
    return MessageMenuPlacement(
        Rect.fromLTWH(left, top, width, height), arrowAtTop, arrowX);
  }
}
