import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts"))
from verify_ui_contract import verify


def test_flutter_html_figma_component_registry_has_no_export_ledger_drift():
    assert verify() == ["UI contract drift: PASS (17 components, 326 screens)"]


def test_registry_registers_nudge_and_contact_tag_delivery_surfaces():
    registry = json.loads((Path(__file__).parents[2] / "packages/ui-contracts/changliao-component-registry.json").read_text(encoding="utf-8"))
    required = {
        "nudge-notice": "WeChatNudgeNotice",
        "contact-tag-management": "ContactTagsPage",
        "contact-tag-members": "ContactTagMembersPage",
        "contact-tag-friend-picker": "ContactTagFriendPickerPage",
        "moments-feed-v2": "MomentsPage",
        "moment-interactions": "WeChatMomentTile",
        "moment-personal-cover": "WeChatMomentCoverViewer",
    }
    actual = {item["id"]: item["flutter"]["name"] for item in registry["components"]}
    assert actual.items() >= required.items()
