import 'room_timeline_controller.dart';

enum RoomHistoryDirection { older, newer }

abstract interface class RoomPresentationRevisionSource {
  Object get presentationRevision;
}

/// A caller-owned immutable-fragment continuation. Implementations validate the
/// account, room and direction. Release it on completion, cancellation or error.
abstract interface class RoomHistoryReadCursor {
  void dispose();
}

final class RoomHistoryMessagePage {
  RoomHistoryMessagePage({
    required Iterable<RoomMessageViewModel> messages,
    required this.exhausted,
    required this.fragmentGeneration,
    required this.rawCount,
    this.nextCursor,
    this.gap = false,
    Map<String, String> sourceRoomIds = const {},
  })  : messages = List.unmodifiable(messages),
        sourceRoomIds = Map.unmodifiable(sourceRoomIds);

  /// In requested traversal order: newest first for older, oldest first for newer.
  final List<RoomMessageViewModel> messages;
  final RoomHistoryReadCursor? nextCursor;
  final bool exhausted;
  final bool gap;
  final int fragmentGeneration;

  /// Includes raw rows filtered out of [messages], never inferred from length.
  final int rawCount;
  final Map<String, String> sourceRoomIds;
}

/// Read-only history access, independent from the current presentation window.
abstract interface class RoomPagedHistorySource {
  bool get supportsPagedHistory;
  Future<RoomHistoryMessagePage> readHistoryPage({
    RoomHistoryReadCursor? cursor,
    String? anchorEventId,
    String? sourceRoomId,
    required RoomHistoryDirection direction,
    int rawLimit = 64,
  });
}

/// Autoplay follows the captured fragment's canonical newer domain. Clock-skewed
/// rows on the older side of [completed] cannot become forward successors.
Future<RoomMessageViewModel?> nextUnreadVoiceFromHistory({
  required RoomPagedHistorySource source,
  required RoomMessageViewModel completed,
  required bool Function() isActive,
  required bool Function(String) isPlayed,
}) async {
  RoomHistoryReadCursor? cursor;
  RoomMessageViewModel? best;
  try {
    do {
      if (!isActive()) return null;
      final page = await source.readHistoryPage(
        cursor: cursor,
        anchorEventId: cursor == null ? completed.id : null,
        direction: RoomHistoryDirection.newer,
        rawLimit: 64,
      );
      if (!identical(cursor, page.nextCursor)) cursor?.dispose();
      cursor = page.nextCursor;
      if (!isActive()) return null;
      for (final message in page.messages) {
        if (message.isOwn ||
            message.kind != RoomMessageKind.voice ||
            isPlayed(message.id) ||
            !message.timestamp.isAfter(completed.timestamp)) {
          continue;
        }
        if (best == null || message.timestamp.isBefore(best.timestamp)) {
          best = message;
        }
      }
      if (page.gap || page.exhausted) break;
      if (cursor == null) throw StateError('History continuation missing');
      await Future<void>.delayed(Duration.zero);
    } while (true);
    return best;
  } finally {
    cursor?.dispose();
  }
}
