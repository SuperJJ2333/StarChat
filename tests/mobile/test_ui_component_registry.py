from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts"))
from verify_ui_contract import verify


def test_flutter_html_figma_component_registry_has_no_export_ledger_drift():
    assert verify() == ["UI contract drift: PASS (10 components, 326 screens)"]
