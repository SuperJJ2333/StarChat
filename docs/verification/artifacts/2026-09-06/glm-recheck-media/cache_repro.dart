import 'dart:async';
import 'dart:typed_data';
import 'file:///D:/pythonProject/outsource/StarChat/apps/mobile_flutter/lib/features/matrix/video_poster_session_cache.dart';
Future<void> main() async {
  final disk = <String,Uint8List>{};
  final cache = VideoPosterSessionCache(memoryMaxEntries:1,diskRead:(k) async=>disk[k],diskWrite:(k,b) async {disk[k]=b;},diskDelete:(k) async {disk.remove(k);});
  await cache.load('a',() async=>Uint8List.fromList([1]));
  await cache.load('b',() async=>Uint8List.fromList([2]));
  await cache.clearAll();
  print('clearAll after LRU: disk keys ${disk.keys}; EXPECT empty');
  final started=Completer<void>(), release=Completer<void>();
  final disk2=<String,Uint8List>{};
  final cache2=VideoPosterSessionCache(diskWrite:(k,b) async {started.complete();await release.future;disk2[k]=b;},diskDelete:(k) async {disk2.remove(k);});
  final flight=cache2.load('x',() async=>Uint8List.fromList([3]));
  await started.future;
  await cache2.clearAll();
  release.complete();
  final result=await flight;
  print('clearAll during diskWrite: disk keys ${disk2.keys}, stale=${result.stale}; EXPECT empty and stale=true');
}
