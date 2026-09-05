from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/device_gallery_source.dart')
raw = p.read_text(encoding='utf-8')
old = "import 'dart:typed_data';\n\nimport 'package:photo_manager/photo_manager.dart';"
new = """import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_compress/video_compress.dart';"""
assert old in raw, 'imports anchor missing'
p.write_text(raw.replace(old, new, 1), encoding='utf-8', newline='')
print('imports OK')
