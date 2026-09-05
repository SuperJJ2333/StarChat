from pathlib import Path

p = Path('apps/mobile_flutter/lib/features/matrix/image_picker_page.dart')
raw = p.read_text(encoding='utf-8')

old = """          child: Stack(fit: StackFit.expand, children: [
            Image.memory(photo.thumbnail,
                key: Key('image-picker-thumb-${photo.id}'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: WeChatColors.textTertiary)),"""
new = """          child: Stack(fit: StackFit.expand, children: [
            // 规格#4：视频缩略图懒加载——立即渲染占位，首帧就绪只更新
            // 本 cell（闭包已 memoize，重复 build 不重复抽帧）。
            if (photo.isVideo && photo.firstFrame != null)
              FutureBuilder<Uint8List?>(
                future: photo.firstFrame!(),
                builder: (context, snapshot) => snapshot.hasData &&
                        snapshot.data!.isNotEmpty
                    ? Image.memory(snapshot.data!,
                        key: Key('image-picker-frame-${photo.id}'),
                        fit: BoxFit.cover,
                        gaplessPlayback: true)
                    : _videoPlaceholder(photo),
              )
            else
              Image.memory(photo.thumbnail,
                  key: Key('image-picker-thumb-${photo.id}'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const ColoredBox(color: WeChatColors.textTertiary)),"""
assert old in raw, 'cell anchor missing'
raw = raw.replace(old, new, 1)
p.write_text(raw, encoding='utf-8', newline='')
print('cell OK')
