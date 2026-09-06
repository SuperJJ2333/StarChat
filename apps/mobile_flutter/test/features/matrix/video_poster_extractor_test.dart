import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_extractor.dart';

// 2×2 纯色 PNG（脚本生成，docs/verification/artifacts/2026-09-04/gen_png.py）。
final Uint8List _blackPng =
    Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAC0lEQVR4nGNgQAYAAA4AAamRc7EAAAAASUVORK5CYII='));
final Uint8List _whitePng =
    Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII='));
final Uint8List _darkGreyPng =
    Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGPgAAMGCAUAAq4AYX+qimIAAAAASUVORK5CYII='));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认封面从第零毫秒取首帧，即使首帧为黑场', () async {
    final positions = <int>[];
    final poster = await extractVideoPoster('video.mp4', fetch: (_, position) async {
      positions.add(position);
      return _blackPng;
    });
    expect(positions, [0]);
    expect(poster, same(_blackPng));
  });

  test('帧平均亮度：黑≈0、白≈255、暗灰≈8', () async {
    expect(await frameAverageLuma(_blackPng), lessThan(4));
    expect(await frameAverageLuma(_whitePng), greaterThan(250));
    final grey = await frameAverageLuma(_darkGreyPng);
    expect(grey, inInclusiveRange(4, 12));
  });

  test('多时间点抽取：首帧近黑自动跳到下一个时间点', () async {
    final positions = <int>[];
    final poster = await extractVideoPoster(
      'video.mp4',
      fetch: (path, positionMs) async {
        positions.add(positionMs);
        return positionMs <= 200 ? _blackPng : _whitePng;
      },
      positionsMs: const [200, 500, 1000, 2000],
    );
    expect(poster, same(_whitePng));
    expect(positions, [200, 500], reason: '命中非黑帧后不再继续尝试');
  });

  test('全部时间点近黑：返回 null（调用方回退占位图）', () async {
    final poster = await extractVideoPoster(
      'video.mp4',
      fetch: (path, positionMs) async => _darkGreyPng,
      positionsMs: const [200, 500, 1000, 2000],
    );
    expect(poster, isNull);
  });

  test('抽取失败（null/空字节）继续尝试下一时间点', () async {
    var calls = 0;
    final poster = await extractVideoPoster(
      'video.mp4',
      fetch: (path, positionMs) async {
        calls++;
        return calls < 3 ? null : _whitePng;
      },
      positionsMs: const [200, 500, 1000, 2000],
    );
    expect(poster, same(_whitePng));
    expect(calls, 3);
  });

  test('第一帧就正常：直接返回不多抽', () async {
    final positions = <int>[];
    final poster = await extractVideoPoster(
      'video.mp4',
      fetch: (path, positionMs) async {
        positions.add(positionMs);
        return _whitePng;
      },
      positionsMs: const [200, 500, 1000, 2000],
    );
    expect(poster, same(_whitePng));
    expect(positions, [200]);
  });
}
