import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EmojiMessageGeneratorContractTest(unittest.TestCase):
    def test_generator_preserves_single_grapheme_message_classifier(self):
        tree = ast.parse((ROOT / "scripts/prepare_fluent_emojis.py").read_text(encoding="utf-8"))
        signature = "List<FluentEmoji> fluentEmojisInMessage(String text) {"
        template = next(
            node for node in ast.walk(tree)
            if isinstance(node, ast.List)
            and any(isinstance(item, ast.Constant) and item.value == signature for item in node.elts)
        )
        lines = [ast.literal_eval(item) for item in template.elts]
        start = lines.index(signature)
        generated = "\n".join(lines[start:lines.index("}", start) + 1])
        catalog = (ROOT / "apps/mobile_flutter/lib/features/emoji/fluent_emoji_catalog.dart").read_text(encoding="utf-8")
        self.assertEqual(generated, catalog[catalog.index(signature):].strip())


if __name__ == "__main__":
    unittest.main()
