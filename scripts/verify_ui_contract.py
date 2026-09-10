"""Executable Flutter–HTML design-demo drift validator."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).parents[1]
REGISTRY_PATH = ROOT / "packages/ui-contracts/changliao-component-registry.json"


def verify() -> list[str]:
    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    assert "figma" not in registry, "Figma export ledger retired; UI changes deliver the HTML demo only"
    contracts = (ROOT / "frontend/src/catalog/contracts.js").read_text(encoding="utf-8")
    css_tokens = (ROOT / "frontend/src/styles/tokens.css").read_text(encoding="utf-8")
    tokens = (ROOT / "apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart").read_text(encoding="utf-8")

    result = subprocess.run(
        ["node", "-e", "import('./frontend/src/catalog/screens.js').then(({screens}) => console.log(screens.length))"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    assert int(result.stdout.strip()) == registry["screens"]["expectedCount"]

    brand = registry["brand"]
    assert brand["internalAssetCode"] == "CAIBI"
    assert brand["productDisplayName"] == "畅聊 ChatFlow"
    assert brand["caibiDisplayName"] == "点钻"
    assert brand["caibiRedPacketLabel"] == "畅聊点钻红包"
    user_visible_sources = [
        ROOT / "apps/mobile_flutter/lib",
        ROOT / "frontend/src",
        ROOT / "services/business-worker/app/integrations/email_sender.py",
        ROOT / "services/business-api/app/api/identity.py",
        ROOT / "services/business-api/app/modules/support/service.py",
        ROOT / "UI_DESIGN.md",
    ]
    user_visible_text = "\n".join(
        path.read_text(encoding="utf-8")
        for item in user_visible_sources
        for path in ([item] if item.is_file() else item.rglob("*"))
        if path.is_file() and path.suffix in {".dart", ".js", ".py", ".md"}
    )
    assert "彩币" not in user_visible_text, "User-visible asset naming drift: 彩币"
    assert "畅聊彩币红包" not in user_visible_text, "User-visible red-packet naming drift"
    assert "六合通" not in user_visible_text, "User-visible product naming drift: 六合通"
    for required in (brand["productDisplayName"], brand["caibiDisplayName"], brand["caibiRedPacketLabel"]):
        assert required in user_visible_text, f"User-visible brand text missing: {required}"

    for group, values in registry["tokenMappings"].items():
        for value in values:
            assert value in tokens, f"Flutter token missing: {group}/{value}"
    for token in registry["tokenParity"]:
        html_name = token["html"].split(":", 1)[0]
        assert html_name in css_tokens, f"HTML token missing: {html_name}"
        assert token["flutter"] in tokens, f"Flutter token drift: {token['flutter']}"

    page_sources = list((ROOT / "apps/mobile_flutter/lib/features").rglob("*.dart"))
    direct_scaffolds = [
        path.relative_to(ROOT).as_posix()
        for path in page_sources
        if "CupertinoPageScaffold(" in path.read_text(encoding="utf-8")
    ]
    assert direct_scaffolds == ["apps/mobile_flutter/lib/features/auth/login_page.dart"], (
        f"Page scaffold drift: {direct_scaffolds}"
    )

    for component in registry["components"]:
        flutter = component["flutter"]
        source = ROOT / flutter["file"]
        body = source.read_text(encoding="utf-8")
        assert re.search(rf"(?:final )?class {re.escape(flutter['name'])}\b", body)
        for prop in flutter["props"]:
            assert prop in body, f"Flutter prop missing: {flutter['name']}.{prop}"
        assert f'tagName: "{component["html"]["tag"]}"' in contracts
    return [f"UI contract drift: PASS ({len(registry['components'])} components, {registry['screens']['expectedCount']} screens)"]


if __name__ == "__main__":
    print("\n".join(verify()))
