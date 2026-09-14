import 'package:flutter/foundation.dart';

/// Raw local timestamp metadata for calendar markers. It intentionally carries
/// no message body, member, media, or presentation projection.
@immutable
final class RoomHistoryDayMetadata {
  const RoomHistoryDayMetadata(this.day);
  final DateTime day;
}

@immutable
final class RoomHistoryDayLocation {
  const RoomHistoryDayLocation({required this.eventId, required this.day});
  final String eventId;
  final DateTime day;
}

/// The remote context still has pages after the bounded date scan. This is
/// deliberately distinct from a confirmed day without a displayable message.
final class RoomHistoryLookupIncomplete implements Exception {
  const RoomHistoryLookupIncomplete();
}

/// A newer date selection, return-to-live action, or lease cancellation won.
final class RoomHistoryLookupCancelled implements Exception {
  const RoomHistoryLookupCancelled();
}

/// Optional bounded date lookup. Legacy timeline adapters remain valid.
abstract interface class RoomHistoryDateCapability {
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata;
  bool get isViewingHistoryContext;
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay);
  void cancelPendingDateLookup();
  void selectLatest();
}
