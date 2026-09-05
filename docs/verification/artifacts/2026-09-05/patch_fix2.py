from pathlib import Path

# room_page：import 修正 + widget.matrix → room.client
p = Path('apps/mobile_flutter/lib/features/matrix/room_page.dart')
raw = p.read_text(encoding='utf-8')
raw = raw.replace(
    "import 'conversation_preferences.dart';",
    "import 'conversation_preferences.dart';\n"
    "import '../../core/permissions/interaction_permission.dart';", 1)
raw = raw.replace(
    "final selfId = widget.matrix.sdkClient.userID;",
    "final selfId = widget.room.client.userID;", 1)
p.write_text(raw, encoding='utf-8', newline='')
print('room_page fix OK')

# home_page：navigator 先取，避开 async-gap lint
p = Path('apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart')
raw = p.read_text(encoding='utf-8')
old = """  Future<void> _openRoom(Room room) async {
    if (_openingRoom) return;"""
new = """  Future<void> _openRoom(Room room) async {
    if (_openingRoom) return;
    // Navigator 先行捕获：后续任何 await 之后都不再触碰 context。
    final navigator = Navigator.of(context, rootNavigator: true);"""
assert old in raw
raw = raw.replace(old, new, 1)
raw = raw.replace(
    "      unawaited(_warmChatIdentity(context));",
    "      unawaited(_warmChatIdentity());", 1)
raw = raw.replace(
    "  Future<void> _warmChatIdentity(BuildContext context) async {",
    "  Future<void> _warmChatIdentity() async {", 1)
raw = raw.replace(
    "      await _identityCache.precacheAvatarImages(context);",
    "      await _identityCache.precacheAvatarImages(this.context);", 1)
raw = raw.replace(
    """      await Navigator.of(context, rootNavigator: true).push(
        CupertinoPageRoute(
          builder: (_) => RoomPage(""",
    """      await navigator.push(
        CupertinoPageRoute(
          builder: (_) => RoomPage(""", 1)
p.write_text(raw, encoding='utf-8', newline='')
print('home fix OK')
