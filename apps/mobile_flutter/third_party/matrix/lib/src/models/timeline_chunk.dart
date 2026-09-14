import 'package:matrix/matrix.dart';

class TimelineChunk {
  String prevBatch; // pos of the first event of the database timeline chunk
  String nextBatch;
  final bool isFragment;

  List<Event> events;
  TimelineChunk(
      {required this.events,
      this.prevBatch = '',
      this.nextBatch = '',
      this.isFragment = false});
}
