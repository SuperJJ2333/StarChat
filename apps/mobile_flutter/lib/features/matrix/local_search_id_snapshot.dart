/// One room query's ordered local event IDs. The Matrix database adapter may
/// keep the IDs in memory or use bounded page anchors for very large rooms.
abstract interface class LocalSearchIdSnapshot {
  Future<List<String>> page(int offset, int limit);
  void dispose();
}
