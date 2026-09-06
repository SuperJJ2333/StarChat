import 'dart:async';
import 'dart:typed_data';
import 'file:///D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/matrix/video_poster_session_cache.dart';
Future<void> main() async {
  final disk = <String, Uint8List>{};
  final cache = VideoPosterSessionCache(diskRead: (k) async => disk[k], diskWrite: (k,v) async { disk[k]=v; }, diskDelete: (k) async { disk.remove(k); });
  final delayed = Completer<Uint8List?>();
  final pending = cache.load('old', () => delayed.future);
  await Future<void>.delayed(Duration.zero);
  await cache.evict('old');
  delayed.complete(Uint8List.fromList([1]));
  await pending;
  print('after evict during load: memoryEntries=${cache.memoryEntries}, diskHasOld=${disk.containsKey("old")}');
  await cache.clearAll();
  final result = await cache.load('old', () async => throw StateError('must not load'));
  print('after clearAll: fromDisk=${result.fromDisk}, bytes=${result.bytes}');
}
