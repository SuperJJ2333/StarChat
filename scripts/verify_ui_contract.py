"""Executable Flutter–HTML–Figma export-ledger drift validator."""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).parents[1]
REGISTRY_PATH = ROOT / "packages/ui-contracts/changliao-component-registry.json"


def verify() -> list[str]:
    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    figma_path = ROOT / registry["figma"]["stateArtifact"]
    figma = json.loads(figma_path.read_text(encoding="utf-8"))
    contracts = (ROOT / "design-demo/src/catalog/contracts.js").read_text(encoding="utf-8")
    css_tokens = (ROOT / "design-demo/src/styles/tokens.css").read_text(encoding="utf-8")
    tokens = (ROOT / "apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart").read_text(encoding="utf-8")

    assert figma["fileKey"] == registry["figma"]["fileKey"]
    assert figma["phase"] == "complete" and figma["step"] == "verified"
    assert not figma["pendingValidations"]
    result = subprocess.run(
        ["node", "-e", "import('./design-demo/src/catalog/screens.js').then(({screens}) => console.log(screens.length))"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    )
    assert int(result.stdout.strip()) == registry["figma"]["expectedScreenCount"]

    figma_variables = figma["entities"]["variables"]
    for group, values in registry["tokenMappings"].items():
        for value in values:
            assert value in tokens, f"Flutter token missing: {group}/{value}"
    for token in registry["tokenParity"]:
        assert token["figma"] in figma_variables, f"Figma token missing: {token['figma']}"
        assert token["html"] in css_tokens, f"HTML token drift: {token['html']}"
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
        assert figma["entities"]["components"].get(component["figma"]["name"]) == component["figma"]["key"]
    return [f"UI contract drift: PASS ({len(registry['components'])} components, {registry['figma']['expectedScreenCount']} screens)"]


if __name__ == "__main__":
    print("\n".join(verify()))
