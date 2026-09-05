from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/image_picker_page.dart')
raw = p.read_text(encoding='utf-8')

# 在 _formatDuration 附近追加 _videoPlaceholder 帮手（找到类内锚点）
anchor = "String _formatDuration("
assert anchor in raw
helper = """Widget _videoPlaceholder(GalleryPhoto photo) => const ColoredBox(
      color: Color(0xFF3A3A3A),
      child: Center(
        child: Icon(CupertinoIcons.videocam_fill,
            size: 22, color: CupertinoColors.white.withOpacity(0.5)),
      ),
    );

  String _formatDuration("""
raw = raw.replace(anchor, helper, 1)

# 确认 Uint8List 已可用（dart:typed_data 导入）
if "import 'dart:typed_data';" not in raw:
    raw = raw.replace("import 'dart:async';", "import 'dart:async';\nimport 'dart:typed_data';", 1)
    if "import 'dart:typed_data';" not in raw:
        raw = "import 'dart:typed_data';\n" + raw
p.write_text(raw, encoding='utf-8', newline='')
print('placeholder OK')
