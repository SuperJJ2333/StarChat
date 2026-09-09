"""Regenerate the reviewable, zero-fuzz patch from pristine Synapse 1.132.0."""
import ast
import difflib
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def method(source, name, transform):
    tree = ast.parse(source)
    nodes = [node for node in ast.walk(tree)
             if isinstance(node, (ast.AsyncFunctionDef, ast.FunctionDef)) and node.name == name]
    assert len(nodes) == 1, name
    node = nodes[0]
    lines = source.splitlines(keepends=True)
    start = node.lineno - 1
    return "".join(lines[:start]) + transform("".join(lines[start:node.end_lineno])) + "".join(lines[node.end_lineno:])


def generate(root):
    updates = {}
    path = "synapse/media/media_repository.py"
    text = (root / path).read_text(encoding="utf-8")
    text = text.replace("import errno\n", "import errno\nfrom synapse.media.chatflow_media_dedup import ContentAddressedMedia\n", 1)
    for name, delegate, params, forwarded in [
        ("create_content", "create", "media_type, upload_name, content, content_length, auth_user", "media_type, upload_name, content, content_length, auth_user"),
        ("update_content", "update", "media_id, media_type, upload_name, content, content_length, auth_user", "media_id, media_type, upload_name, content, content_length, auth_user"),
        ("_remove_local_media_from_disk", "purge", "media_ids", "media_ids"),
    ]:
        original_name = {"create_content": "_chatflow_create_content_original", "update_content": "_chatflow_update_content_original", "_remove_local_media_from_disk": "_chatflow_remove_local_media_original"}[name]
        wrapper = f"    async def {name}(self, {params}):\n        return await ContentAddressedMedia(self).{delegate}({forwarded})\n\n"
        text = method(text, name, lambda body, n=name, o=original_name, w=wrapper: w + body.replace(f"def {n}(", f"def {o}(", 1))
    text = method(text, "delete_local_media_ids", lambda _: "    async def delete_local_media_ids(self, media_ids, user_id=None):\n        return await ContentAddressedMedia(self).delete(media_ids, user_id)\n")
    text = method(text, "_chatflow_create_content_original", lambda body: body.replace(
        "auth_user: UserID,\n    ) -> MXCUri:",
        "auth_user: UserID,\n        _chatflow_media_id: Optional[str] = None,\n    ) -> MXCUri:",
        1).replace("media_id = random_string(24)", "media_id = _chatflow_media_id or random_string(24)", 1))
    updates[path] = text

    path = "synapse/storage/databases/main/media_repository.py"
    text = (root / path).read_text(encoding="utf-8")
    text = method(text, "get_local_media_by_user_paginate", lambda body: body.replace("FROM local_media_repository", "FROM chatflow_media_user_view"))
    updates[path] = text

    path = "synapse/storage/databases/main/stats.py"
    text = (root / path).read_text(encoding="utf-8")
    text = method(text, "get_users_media_usage_paginate", lambda body: body.replace("FROM local_media_repository as lmr", "FROM chatflow_media_user_view as lmr"))
    updates[path] = text

    path = "synapse/storage/databases/main/room.py"
    text = (root / path).read_text(encoding="utf-8")
    text = text.replace("import logging\n", "import logging\nfrom synapse.media.chatflow_media_dedup import media_lifecycle\n", 1)
    text = method(text, "_get_media_ids_by_user_txn", lambda body: body.replace("FROM local_media_repository", "FROM chatflow_media_user_view"))
    for name in ("quarantine_media_ids_in_room", "quarantine_media_by_id", "quarantine_media_ids_by_user"):
        text = method(text, name, lambda body: "    @media_lifecycle\n" + body)
    updates[path] = text

    path = "synapse/rest/admin/media.py"
    text = (root / path).read_text(encoding="utf-8")
    old = "[m.media_id for m in media]\n"
    assert text.count(old) == 1
    updates[path] = text.replace(old, "[m.media_id for m in media], user_id=user_id\n")

    manifest, patch = {}, []
    for path, updated in updates.items():
        original = (root / path).read_text(encoding="utf-8")
        ast.parse(updated)
        manifest[path] = {"before": hashlib.sha256(original.encode()).hexdigest(), "after": hashlib.sha256(updated.encode()).hexdigest()}
        patch.extend(difflib.unified_diff(original.splitlines(True), updated.splitlines(True), fromfile="a/" + path, tofile="b/" + path))
    (HERE / "patches").mkdir(exist_ok=True)
    (HERE / "patches/0001-cross-user-media-dedup.patch").write_text("".join(patch), encoding="utf-8", newline="\n")
    (HERE / "upstream-manifest.json").write_text(json.dumps({"version": "1.132.0", "files": manifest}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    generate(Path(sys.argv[1]))
