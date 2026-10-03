/// Optional direct event locator. Implementations own one bounded context and
/// preserve their live latest timeline. No SDK objects cross this interface.
abstract interface class RoomEventContextCapability {
  bool get supportsEventContext;
  Future<bool> locateEvent(String eventId);
  void cancelPendingEventLookup();
}
