"""从 microsoft/fluentui-emoji 下载精选静态表情的 Color 风格 SVG 并生成 Dart 目录表。

来源：https://github.com/microsoft/fluentui-emoji（MIT License）
- 有肤色变体（人物表情/手势）取 Default 肤色：`assets/<Name>/Default/Color/*_color_default.svg`
- 无肤色变体取：`assets/<Name>/Color/*_color.svg`
- SVG 为矢量资产：Flutter 侧按 widget 尺寸 × DPR 栅格化，任意分辨率下锐利无锯齿。

产物：
  apps/mobile_flutter/assets/emoji_vector/<slug>.svg
  apps/mobile_flutter/lib/features/emoji/fluent_vector_emoji_catalog.dart
"""
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

GITHUB_REPO = "microsoft/fluentui-emoji"
GITHUB_REF = "main"
GITHUB_TREE_URL = (
    f"https://api.github.com/repos/{GITHUB_REPO}/git/trees/{GITHUB_REF}?recursive=1"
)
GITHUB_RAW = f"https://raw.githubusercontent.com/{GITHUB_REPO}/{GITHUB_REF}/"
JSDR_CDN = f"https://cdn.jsdelivr.net/gh/{GITHUB_REPO}@{GITHUB_REF}/"

OUT_ASSETS = os.path.join("apps", "mobile_flutter", "assets", "emoji_vector")
OUT_DART = os.path.join(
    "apps",
    "mobile_flutter",
    "lib",
    "features",
    "emoji",
    "fluent_vector_emoji_catalog.dart",
)

RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = 2.0

# (fluentui-emoji 仓库目录名, unicode 字符) —— 目录名必须与仓库 assets/ 下完全一致。
# 覆盖动效目录（fluent_emoji_catalog）全部字符 + 常用补充，作为“普通emoji”矢量渲染集。
CURATED = [
    # --- Smileys and emotion ---
    ("Grinning face", "😀"),
    ("Grinning face with big eyes", "😄"),
    ("Grinning face with smiling eyes", "😁"),
    ("Face with tears of joy", "😂"),
    ("Rolling on the floor laughing", "🤣"),
    ("Smiling face with smiling eyes", "😊"),
    ("Slightly smiling face", "🙂"),
    ("Smiling face with halo", "😇"),
    ("Smiling face with heart-eyes", "😍"),
    ("Smiling face with hearts", "🥰"),
    ("Face blowing a kiss", "😘"),
    ("Face savoring food", "😋"),
    ("Winking face", "😉"),
    ("Smiling face with sunglasses", "😎"),
    ("Smirking face", "😏"),
    ("Flushed face", "😳"),
    ("Grinning face with sweat", "😅"),
    ("Face holding back tears", "🥲"),
    ("Upside-down face", "🙃"),
    ("Hugging face", "🤗"),
    ("Star-struck", "🤩"),
    ("Shushing face", "🤫"),
    ("Thinking face", "🤔"),
    ("Face with raised eyebrow", "🤨"),
    ("Neutral face", "😐"),
    ("Expressionless face", "😑"),
    ("Face without mouth", "😶"),
    ("Unamused face", "😒"),
    ("Face with rolling eyes", "🙄"),
    ("Face screaming in fear", "😱"),
    ("Astonished face", "😲"),
    ("Zany face", "🤪"),
    ("Nerd face", "🤓"),
    ("Partying face", "🥳"),
    ("Relieved face", "😌"),
    ("Sleepy face", "😪"),
    ("Sleeping face", "😴"),
    ("Pleading face", "🥺"),
    ("Crying face", "😢"),
    ("Loudly crying face", "😭"),
    ("Disappointed face", "😞"),
    ("Downcast face with sweat", "😓"),
    ("Face with medical mask", "😷"),
    ("Face with thermometer", "🤒"),
    ("Sneezing face", "🤧"),
    ("Hot face", "🥵"),
    ("Cold face", "🥶"),
    ("Exploding head", "🤯"),
    ("Pouting face", "😡"),
    ("Angry face", "😠"),
    ("Face with symbols on mouth", "🤬"),
    ("Saluting face", "🫡"),
    ("Melting face", "🫠"),
    ("Grimacing face", "😬"),
    ("Lying face", "🤥"),
    ("Face with open mouth", "😮"),
    ("Hushed face", "😯"),
    ("Confused face", "😕"),
    ("Worried face", "😟"),
    ("Slightly frowning face", "🙁"),
    ("Weary face", "😩"),
    ("Tired face", "😫"),
    ("Yawning face", "🥱"),
    # --- People and body ---
    ("Thumbs up", "👍"),
    ("Thumbs down", "👎"),
    ("Ok hand", "👌"),
    ("Victory hand", "✌"),
    ("Crossed fingers", "🤞"),
    ("Love-you gesture", "🤟"),
    ("Sign of the horns", "🤘"),
    ("Call me hand", "🤙"),
    ("Pinching hand", "🤏"),
    ("Waving hand", "👋"),
    ("Clapping hands", "👏"),
    ("Folded hands", "🙏"),
    ("Flexed biceps", "💪"),
    ("Raised fist", "✊"),
    ("Oncoming fist", "👊"),
    ("Handshake", "🤝"),
    ("Open hands", "👐"),
    ("Raised hand", "✋"),
    ("Index pointing up", "☝"),
    # --- Hearts ---
    ("Red heart", "❤"),
    ("Orange heart", "🧡"),
    ("Yellow heart", "💛"),
    ("Green heart", "💚"),
    ("Blue heart", "💙"),
    ("Purple heart", "💜"),
    ("Black heart", "🖤"),
    ("White heart", "🤍"),
    ("Brown heart", "🤎"),
    ("Broken heart", "💔"),
    ("Two hearts", "💕"),
    ("Revolving hearts", "💞"),
    ("Beating heart", "💓"),
    ("Growing heart", "💗"),
    ("Sparkling heart", "💖"),
    ("Heart with arrow", "💘"),
    ("Heart with ribbon", "💝"),
    ("Love letter", "💌"),
    ("Heart decoration", "💟"),
    # --- Symbols ---
    ("Hundred points", "💯"),
    ("Collision", "💥"),
    ("Sparkles", "✨"),
    ("Star", "⭐"),
    ("Glowing star", "🌟"),
    ("Shooting star", "🌠"),
    ("Fire", "🔥"),
    ("Party popper", "🎉"),
    ("Confetti ball", "🎊"),
    ("Balloon", "🎈"),
    ("Rocket", "🚀"),
    ("High voltage", "⚡"),
    ("Check mark button", "✅"),
    ("Cross mark", "❌"),
    ("Red exclamation mark", "❗"),
    ("Red question mark", "❓"),
    ("Warning", "⚠"),
    ("Trophy", "🏆"),
    ("1st place medal", "🥇"),
    ("Gem stone", "💎"),
    ("Crown", "👑"),
    ("Musical notes", "🎶"),
    ("Musical note", "🎵"),
    # --- Animals and nature ---
    ("Dog face", "🐶"),
    ("Cat face", "🐱"),
    ("Mouse face", "🐭"),
    ("Rabbit face", "🐰"),
    ("Bear", "🐻"),
    ("Panda", "🐼"),
    ("Fox", "🦊"),
    ("Lion", "🦁"),
    ("Tiger face", "🐯"),
    ("Cow face", "🐮"),
    ("Pig face", "🐷"),
    ("Frog", "🐸"),
    ("Monkey face", "🐵"),
    ("Baby chick", "🐤"),
    ("Penguin", "🐧"),
    ("Owl", "🦉"),
    ("Butterfly", "🦋"),
    ("Turtle", "🐢"),
    ("Snake", "🐍"),
    ("Spouting whale", "🐳"),
    ("Fish", "🐟"),
    ("Tropical fish", "🐠"),
    ("Shark", "🦈"),
    ("Honeybee", "🐝"),
    ("Sunflower", "🌻"),
    ("Rose", "🌹"),
    ("Tulip", "🌷"),
    ("Cherry blossom", "🌸"),
    ("Hibiscus", "🌺"),
    ("Bouquet", "💐"),
    ("Four leaf clover", "🍀"),
    ("Leaf fluttering in wind", "🍃"),
    ("Droplet", "💧"),
    ("Crescent moon", "🌙"),
    ("Sun", "☀"),
    ("Rainbow", "🌈"),
    ("Cloud", "☁"),
    ("Umbrella with rain drops", "☔"),
    ("Snowflake", "❄"),
    # --- Food and drink ---
    ("Hot beverage", "☕"),
    ("Beer mug", "🍺"),
    ("Clinking beer mugs", "🍻"),
    ("Bottle with popping cork", "🍾"),
    ("Wine glass", "🍷"),
    ("Cocktail glass", "🍸"),
    ("Clinking glasses", "🥂"),
    ("Cup with straw", "🥤"),
    ("Bubble tea", "🧋"),
    ("Birthday cake", "🎂"),
    ("Shortcake", "🍰"),
    ("Cupcake", "🧁"),
    ("Cookie", "🍪"),
    ("Doughnut", "🍩"),
    ("Chocolate bar", "🍫"),
    ("Candy", "🍬"),
    ("Lollipop", "🍭"),
    ("Soft ice cream", "🍦"),
    ("Ice cream", "🍨"),
    ("Pizza", "🍕"),
    ("Hamburger", "🍔"),
    ("French fries", "🍟"),
    ("Hot dog", "🌭"),
    ("Sandwich", "🥪"),
    ("Taco", "🌮"),
    ("Sushi", "🍣"),
    ("Steaming bowl", "🍜"),
    ("Dumpling", "🥟"),
    ("Bento box", "🍱"),
    ("Cooked rice", "🍚"),
    ("Red apple", "🍎"),
    ("Green apple", "🍏"),
    ("Banana", "🍌"),
    ("Watermelon", "🍉"),
    ("Grapes", "🍇"),
    ("Melon", "🍈"),
    ("Tangerine", "🍊"),
    ("Lemon", "🍋"),
    ("Pineapple", "🍍"),
    ("Mango", "🥭"),
    ("Peach", "🍑"),
    ("Cherries", "🍒"),
    ("Strawberry", "🍓"),
    ("Kiwi fruit", "🥝"),
    ("Tomato", "🍅"),
    ("Avocado", "🥑"),
    # --- Objects / travel / activities ---
    ("Wrapped gift", "🎁"),
    ("Camera", "📷"),
    ("Bell", "🔔"),
    ("Artist palette", "🎨"),
    ("Soccer ball", "⚽"),
    ("Basketball", "🏀"),
    ("Ping pong", "🏓"),
    ("Automobile", "🚗"),
    ("Taxi", "🚕"),
    ("Airplane", "✈"),
    ("Ship", "🚢"),
    ("Bicycle", "🚲"),
    ("Fireworks", "🎆"),
    ("Sparkler", "🎇"),
    ("T-shirt", "👕"),
    ("Glasses", "👓"),
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
    raise RuntimeError(
        f"download failed after {RETRY_ATTEMPTS} attempts: {url}"
    ) from last_error


def fetch_svg_paths():
    """返回 {仓库目录名: [候选 SVG 路径]}，仅保留 Color 风格（Default 肤色优先）。"""
    data = json.loads(_http_get(GITHUB_TREE_URL, timeout=120))
    if data.get("truncated"):
        raise RuntimeError("GitHub tree response was truncated; cannot proceed")
    by_folder = {}
    for entry in data["tree"]:
        path = entry.get("path", "")
        if entry.get("type") != "blob" or not path.endswith(".svg"):
            continue
        if not path.endswith("_color_default.svg") and not path.endswith("_color.svg"):
            continue
        match = re.match(r"assets/([^/]+)/", path)
        if match:
            by_folder.setdefault(match.group(1), []).append(path)
    for paths in by_folder.values():
        paths.sort(key=lambda p: not p.endswith("_color_default.svg"))
    return by_folder


def slugify(folder):
    return re.sub(r"[^a-z0-9]+", "-", folder.lower()).strip("-")


def download(path):
    try:
        return _http_get(JSDR_CDN + urllib.parse.quote(path))
    except RuntimeError:
        return _http_get(GITHUB_RAW + urllib.parse.quote(path))


def main():
    os.makedirs(OUT_ASSETS, exist_ok=True)
    os.makedirs(os.path.dirname(OUT_DART), exist_ok=True)
    sys.stdout.write("fetching fluentui-emoji file tree...\n")
    by_folder = fetch_svg_paths()
    print(f"folders with color svg: {len(by_folder)}")

    resolved = []
    missing = []
    for folder, char in CURATED:
        candidates = by_folder.get(folder)
        if not candidates:
            missing.append(folder)
            continue
        resolved.append((slugify(folder), folder, char, candidates[0]))

    if missing:
        print("MISSING FOLDERS:")
        for folder in missing:
            print(" -", folder)
        raise SystemExit(1)

    names = [item[0] for item in resolved]
    duplicates = {name for name in names if names.count(name) > 1}
    if duplicates:
        raise SystemExit(f"duplicate slugs: {sorted(duplicates)}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        payloads = list(
            pool.map(
                lambda item: (item[0], item[1], item[2], item[3], download(item[3])),
                resolved,
            )
        )

    generated = []
    for slug, folder, char, path, payload in payloads:
        out_path = os.path.join(OUT_ASSETS, f"{slug}.svg")
        with open(out_path, "wb") as handle:
            handle.write(payload)
        generated.append((slug, char, f"assets/emoji_vector/{slug}.svg"))
        print(f"OK {slug:34s} {len(payload)/1024:6.1f} KB  <- {path}")

    chars = [char for _slug, char, _asset in generated]
    if len(set(chars)) != len(chars):
        raise SystemExit("duplicate unicode chars in generated catalog")

    dart = [
        "// GENERATED by scripts/prepare_fluent_vector_emojis.py — do not edit.",
        "// Static vector emojis (Color style, Default skin tone)",
        "// (c) Microsoft fluentui-emoji, MIT License.",
        "final class VectorEmoji {",
        "  const VectorEmoji({required this.char, required this.name, required this.asset});",
        "",
        "  final String char; // unicode character inside the encrypted text message",
        "  final String name;",
        "  final String asset; // vector SVG bundled with the app",
        "}",
        "",
        "const vectorEmojis = <VectorEmoji>[",
    ]
    for slug, char, asset in generated:
        dart.append(
            "  VectorEmoji(char: '%s', name: '%s', asset: '%s'),"
            % (char, slug, asset)
        )
    dart.extend(
        [
            "];",
            "",
            "final Map<String, VectorEmoji> _vectorEmojisByChar = {",
            "  for (final emoji in vectorEmojis) emoji.char: emoji,",
            "};",
            "",
            "/// 按 Unicode 字素查找矢量表情；未命中时剥离 VS16（U+FE0F）再查一次，",
            "/// 使系统键盘输入的 '❤️'（U+2764 U+FE0F）可解析到目录中的 '❤'。",
            "VectorEmoji? vectorEmojiByChar(String char) {",
            "  final exact = _vectorEmojisByChar[char];",
            "  if (exact != null) return exact;",
            "  if (char.contains('\\uFE0F')) {",
            "    return _vectorEmojisByChar[char.replaceAll('\\uFE0F', '')];",
            "  }",
            "  return null;",
            "}",
        ]
    )
    with open(OUT_DART, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(dart) + "\n")
    print(f"generated {len(generated)} vector emojis -> {OUT_DART}")


if __name__ == "__main__":
    main()
