import 'dart:async';
import 'dart:typed_data';
import '../../../../../apps/mobile_flutter/lib/features/matrix/video_poster_session_cache.dart';
Future<void> main() async {
 final disk=<String,Uint8List>{};
 final entered=Completer<void>(), release=Completer<void>();
 final cache=VideoPosterSessionCache(diskRead:(k) async=>disk[k],diskWrite:(k,b) async{entered.complete(); await release.future; disk[k]=b;},diskDelete:(k) async{disk.remove(k);},diskListKeys:()async=>disk.keys.toList());
 final flight=cache.load('A',()async=>Uint8List.fromList([1]));
 await entered.future;
 await cache.clearAll();
 release.complete();
 final result=await flight;
 print('clear during diskWrite: expected disk empty=true actual=${disk.isEmpty}; expected stale=true actual=${result.stale}');
 final readEntered=Completer<void>(), readRelease=Completer<void>();
 final readCache=VideoPosterSessionCache(diskRead:(k) async{readEntered.complete();await readRelease.future;return Uint8List.fromList([2]);});
 final readFlight=readCache.load('B',()async=>null);
 await readEntered.future; await readCache.evict('B'); readRelease.complete();
 final readResult=await readFlight;
 print('evict during diskRead: expected stale=true actual=${readResult.stale}; bytes still returned=${readResult.bytes != null}');
}
