import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts"))
from verify_ui_contract import verify


def test_flutter_html_component_registry_has_no_drift():
    assert verify() == ["UI contract drift: PASS (20 components, 331 screens)"]


def test_ui_contract_is_html_demo_only_without_figma_ledger():
    registry = json.loads((Path(__file__).parents[2] / "packages/ui-contracts/changliao-component-registry.json").read_text(encoding="utf-8"))
    assert "figma" not in registry
    assert registry["screens"]["expectedCount"] == 331
    assert all("figma" not in token for token in registry["tokenParity"])
    assert all("figma" not in component for component in registry["components"])


def test_registry_registers_nudge_and_contact_tag_delivery_surfaces():
    registry = json.loads((Path(__file__).parents[2] / "packages/ui-contracts/changliao-component-registry.json").read_text(encoding="utf-8"))
    required = {
        "nudge-notice": "WeChatNudgeNotice",
        "contact-tag-management": "ContactTagsPage",
        "contact-tag-members": "ContactTagMembersPage",
        "contact-tag-friend-picker": "ContactTagFriendPickerPage",
        "moments-feed-v2": "MomentsPage",
        "moment-interactions": "WeChatMomentTile",
        "moment-reactions": "WeChatMomentReactions",
        "shared-profile-identity": "ProfileIdentityCard",
        "moment-personal-cover": "WeChatMomentCoverViewer",
    }
    actual = {item["id"]: item["flutter"]["name"] for item in registry["components"]}
    assert actual.items() >= required.items()
