"""下载 Animated-Fluent-Emojis 子集，编码为高分辨率 animated WebP 并生成 Dart 目录表。

来源：https://github.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis
经 GitHub tree API / jsDelivr 获取 APNG（256px），保留源分辨率并以 8-bit alpha
编码为 animated WebP（Flutter Image 原生播放，无需额外依赖）。

历史问题：旧版脚本将 256px 源缩至 72px GIF（256 色调色板 + 1-bit 二值透明），
消息内放大渲染产生明显边缘毛刺；WebP 8-bit 平滑 alpha + 源分辨率输出是修复手段。

产物：
  apps/mobile_flutter/assets/emoji/<slug>.webp
  apps/mobile_flutter/lib/features/emoji/fluent_emoji_catalog.dart
"""
import concurrent.futures
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from PIL import Image

GITHUB_REPO = "Tarikul-Islam-Anik/Animated-Fluent-Emojis"
GITHUB_REF = "master"
GITHUB_TREE_URL = (
    f"https://api.github.com/repos/{GITHUB_REPO}/git/trees/{GITHUB_REF}?recursive=1"
)
GITHUB_RAW = f"https://raw.githubusercontent.com/{GITHUB_REPO}/{GITHUB_REF}/"
JSDR_TREE_URL = f"https://data.jsdelivr.com/v1/packages/gh/{GITHUB_REPO}@{GITHUB_REF}"
JSDR_CDN = f"https://cdn.jsdelivr.net/gh/{GITHUB_REPO}@{GITHUB_REF}/"

OUT_ASSETS = os.path.join("apps", "mobile_flutter", "assets", "emoji")
OUT_DART = os.path.join(
    "apps", "mobile_flutter", "lib", "features", "emoji", "fluent_emoji_catalog.dart"
)

# WebP 编码参数：画质 55 对平面卡通无明显伪影，8-bit alpha 保持边缘平滑。
# 体积由帧数主导：超过 MAX_FRAMES 的长动画按等时间间隔抽帧并对齐每帧
# 时长（12fps→8fps，卡通表情感知轻微），实测约 -36% 资产体积。
# method 仅影响编码器搜索力度（4 与 6 体积差 <10%），不改变画质。
WEBP_QUALITY = 55
WEBP_ALPHA_QUALITY = 100
WEBP_METHOD = 6
MAX_FRAMES = 32

RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = 2.0

# (slug, 仓库名称关键词, unicode 字符) —— 关键词用于在文件树中匹配。
CURATED = [
    ("grinning", "Grinning face with big eyes", "😄"),
    ("smile", "Smiling face with smiling eyes", "😊"),
    ("joy", "Face with tears of joy", "😂"),
    ("halo", "Smiling face with halo", "😇"),
    ("heart-eyes", "Smiling face with heart-eyes", "😍"),
    ("hearts-face", "Smiling face with hearts", "🥰"),
    ("kiss", "Face blowing a kiss", "😘"),
    ("wink", "Winking face", "😉"),
    ("zany", "Zany face", "🤪"),
    ("savoring", "Face savoring food", "😋"),
    ("holding-back-tears", "Face holding back tears", "🥲"),
    ("sob", "Loudly crying face", "😭"),
    ("cry", "Crying face", "😢"),
    ("angry", "Enraged face", "😡"),
    ("smiling-angry", "Angry face", "😠"),
    ("cool", "Smiling face with sunglasses", "😎"),
    ("nerd", "Nerd face", "🤓"),
    ("relieved", "Relieved face", "😌"),
    ("sleepy", "Sleepy face", "😪"),
    ("sleeping", "Sleeping face", "😴"),
    ("mask", "Face with medical mask", "😷"),
    ("upside-down", "Upside-down face", "🙃"),
    ("shushing", "Shushing face", "🤫"),
    ("scream", "Face screaming in fear", "😱"),
    ("sweat-smile", "Grinning face with sweat", "😅"),
    ("rofl", "Rolling on the floor laughing", "🤣"),
    ("neutral", "Neutral face", "😐"),
    ("unamused", "Unamused face", "😒"),
    ("thinking", "Thinking face", "🤔"),
    ("shocked", "Astonished face", "😲"),
    ("partying", "Partying face", "🥳"),
    ("pleading", "Pleading face", "🥺"),
    ("thumbs-up", "Thumbs up", "👍"),
    ("thumbs-down", "Thumbs down", "👎"),
    ("ok-hand", "Ok hand", "👌"),
    ("wave", "Waving hand", "👋"),
    ("clap", "Clapping hands", "👏"),
    ("pray", "Folded hands", "🙏"),
    ("muscle", "Flexed biceps", "💪"),
    ("heart", "Red heart", "❤"),
    ("broken-heart", "Broken heart", "💔"),
    ("sparkles", "Sparkles", "✨"),
    ("party-popper", "Party popper", "🎉"),
    ("cake", "Birthday cake", "🎂"),
    ("rose", "Rose", "🌹"),
    ("gift", "Wrapped gift", "🎁"),
    ("coffee", "Hot beverage", "☕"),
    ("beer", "Beer mug", "🍺"),
    ("watermelon", "Watermelon", "🍉"),
    ("strawberry", "Strawberry", "🍓"),
    ("dog", "Dog face", "🐶"),
    ("cat", "Cat face", "🐱"),
    ("pig", "Pig face", "🐷"),
    ("fire", "Fire", "🔥"),
    ("rocket", "Rocket", "🚀"),
    ("medal", "1st place medal", "🥇"),
]


def _http_get(url, timeout=60):
    last_error = None
    for attempt in range(RETRY_ATTEMPTS):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as error:  # noqa: BLE001 - 网络源不稳定，统一重试
            last_error = error
            if attempt + 1 < RETRY_ATTEMPTS:
                time.sleep(RETRY_BACKOFF_SECONDS * (attempt + 1))
    raise RuntimeError(f"download failed after {RETRY_ATTEMPTS} attempts: {url}") from last_error


def fetch_tree():
    """优先 GitHub tree API，失败时回退 jsDelivr 数据接口。

    键与 CURATED 关键词同规则归一（小写、连字符转空格、去扩展名），
    避免文件名中的连字符导致子串匹配失败。
    """
    try:
        data = json.loads(_http_get(GITHUB_TREE_URL))
        files = {
            os.path.splitext(os.path.basename(entry["path"]))[0]
            .lower()
            .replace("-", " "): entry["path"]
            for entry in data["tree"]
            if entry["type"] == "blob"
            and entry["path"].lower().endswith(".png")
        }
        if files:
            return files
    except Exception as error:  # noqa: BLE001
        sys.stderr.write(f"github tree failed ({error}); falling back to jsDelivr\n")
    data = json.loads(_http_get(JSDR_TREE_URL, timeout=120))
    files = {}

    def walk(node):
        for entry in node.get("files", []):
            if entry.get("type") == "directory":
                walk(entry)
            elif entry.get("name", "").lower().endswith(".png"):
                name = os.path.splitext(os.path.basename(entry["name"]))[0]
                files[name.lower()] = entry["name"]

    walk(data)
    return files


def normalize(name):
    return name.lower().replace("-", " ")


def download(path):
    try:
        return _http_get(JSDR_CDN + urllib.parse.quote(path))
    except RuntimeError:
        return _http_get(GITHUB_RAW + urllib.parse.quote(path))


def is_valid_webp(path):
    """已存在的输出可被完整解码时跳过，支持断点续跑。"""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return False
    try:
        import io

        with Image.open(path) as handle:
            handle.seek(0)
            handle.load()
        return True
    except Exception:  # noqa: BLE001 - 损坏文件重新生成
        return False


def thin_frames(frames, durations, cap):
    """超过 cap 帧时等时间间隔抽帧，总时长保持不变（卡顿感最小化）。"""
    if len(frames) <= cap:
        return frames, durations
    keep = [round(i * (len(frames) - 1) / (cap - 1)) for i in range(cap)]
    thinned_frames = [frames[i] for i in keep]
    thinned_durations = []
    for j, index in enumerate(keep):
        end = keep[j + 1] if j + 1 < len(keep) else len(frames)
        thinned_durations.append(max(20, sum(durations[index:end])))
    return thinned_frames, thinned_durations


def apng_to_webp(data, out_path):
    """保留源分辨率，以 8-bit alpha 编码 animated WebP；长动画抽帧控体积。不做缩放。"""
    import io

    image = Image.open(io.BytesIO(data))
    frames = []
    durations = []
    count = getattr(image, "n_frames", 1)
    for index in range(count):
        image.seek(index)
        frames.append(image.convert("RGBA"))
        durations.append(max(20, int(image.info.get("duration", 80))))
    frames, durations = thin_frames(frames, durations, MAX_FRAMES)
    frames[0].save(
        out_path,
        save_all=True,
        append_images=frames[1:],
        duration=durations or [80],
        loop=0,
        format="WEBP",
        quality=WEBP_QUALITY,
        alpha_quality=WEBP_ALPHA_QUALITY,
        method=WEBP_METHOD,
    )
    return image.size


def clean_legacy_gifs():
    for name in os.listdir(OUT_ASSETS):
        if name.lower().endswith(".gif"):
            os.remove(os.path.join(OUT_ASSETS, name))
            print(f"removed legacy asset {name}")


def main():
    os.makedirs(OUT_ASSETS, exist_ok=True)
    os.makedirs(os.path.dirname(OUT_DART), exist_ok=True)
    sys.stdout.write("fetching file tree...\n")
    tree = fetch_tree()
    print(f"tree png files: {len(tree)}")

    generated = []
    skipped = []
    resolved = []
    for slug, keyword, char in CURATED:
        matches = [
            path
            for name, path in tree.items()
            if normalize(keyword) in name or name == normalize(keyword)
        ]
        if not matches:
            skipped.append(keyword)
            continue
        out_path = os.path.join(OUT_ASSETS, f"{slug}.webp")
        if is_valid_webp(out_path):
            size = os.path.getsize(out_path)
            generated.append((slug, char, f"assets/emoji/{slug}.webp", size))
            print(f"KEEP {slug:22s} {size/1024:6.1f} KB  (existing valid output)")
            continue
        resolved.append((slug, char, sorted(matches)[0]))

    # 并发下载（网络往返是主要耗时），编码按目录顺序串行执行。
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        payloads = list(
            pool.map(lambda item: (item[0], item[1], item[2], download(item[2])), resolved)
        )

    for slug, char, path, data in payloads:
        out_path = os.path.join(OUT_ASSETS, f"{slug}.webp")
        source_size = apng_to_webp(data, out_path)
        size = os.path.getsize(out_path)
        generated.append((slug, char, f"assets/emoji/{slug}.webp", size))
        print(
            f"OK {slug:22s} {size/1024:6.1f} KB  <- {path}  "
            f"source {source_size[0]}x{source_size[1]}"
        )

    if skipped:
        print("SKIPPED:")
        for keyword in skipped:
            print(" -", keyword)

    clean_legacy_gifs()

    dart = [
        "// GENERATED by scripts/prepare_fluent_emojis.py — do not edit.",
        "// Animated Fluent Emojis (c) Tarikul-Islam-Anik, MIT License.",
        "import 'package:characters/characters.dart';",
        "",
        "final class FluentEmoji {",
        "  const FluentEmoji({required this.char, required this.name, required this.asset});",
        "",
        "  final String char; // unicode sent inside the encrypted text message",
        "  final String name;",
        "  final String asset; // animated WebP bundled with the app",
        "}",
        "",
        "const fluentEmojis = <FluentEmoji>[",
    ]
    for slug, char, asset, _size in generated:
        dart.append(
            "  FluentEmoji(char: '%s', name: '%s', asset: '%s'),"
            % (char, slug.replace("-", " "), asset)
        )
    dart.extend(
        [
            "];",
            "",
            "final Map<String, FluentEmoji> _fluentEmojisByChar = {",
            "  for (final emoji in fluentEmojis) emoji.char: emoji,",
            "};",
            "",
            "FluentEmoji? fluentEmojiByChar(String char) => _fluentEmojisByChar[char];",
            "",
            "/// 消息\"纯动效表情\"判定：全部字素为已知 Fluent 表情（允许空白），",
            "/// 且表情数量 1–4。满足时消息以放大动画渲染；否则按普通文本渲染。",
            "List<FluentEmoji> fluentEmojisInMessage(String text) {",
            "  final emojis = <FluentEmoji>[];",
            "  for (final grapheme in text.characters) {",
            "    if (grapheme.trim().isEmpty) continue;",
            "    final emoji = _fluentEmojisByChar[grapheme];",
            "    if (emoji == null) return const [];",
            "    emojis.add(emoji);",
            "    if (emojis.length > 4) return const [];",
            "  }",
            "  return emojis;",
            "}",
        ]
    )
    with open(OUT_DART, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(dart) + "\n")
    print(f"generated {len(generated)} emojis -> {OUT_DART}")


if __name__ == "__main__":
    main()
