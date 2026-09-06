"""Guard production room wiring missed by isolated profile widget tests."""
from pathlib import Path

ROOM = Path(__file__).resolve().parents[2] / "apps/mobile_flutter/lib/features/matrix/room_page.dart"


def test_room_profile_injects_message_action():
    source = ROOM.read_text(encoding="utf-8")
    profile = source.split("Future<void> _openContact", 1)[1].split("Future<void> _openConversationDetails", 1)[0]
    assert "onMessage: widget.onMessage" in profile


def test_bubble_uses_viewer_owned_remark():
    source = ROOM.read_text(encoding="utf-8")
    sender = source.split("String _senderDisplayName", 1)[1].split("Widget _messageRow", 1)[0]
    assert "contact?.displayName" in sender
    assert "contact?.primaryDisplayName" not in sender


def test_all_bubble_avatar_branches_allow_stranger_profile():
    source = ROOM.read_text(encoding="utf-8")
    row = source.split("Widget _messageRow", 1)[1].split("Future<void> _forwardMessages", 1)[0]
    assert "onAvatarTap: contact == null ? null" not in row
    assert row.count("onAvatarTap: () => _openMessageSender(message)") == 4


def test_direct_details_share_friend_and_stranger_profile_routing():
    source = ROOM.read_text(encoding="utf-8")
    peer = source.split("Future<void> _openPeerProfile", 1)[1].split("Future<void> _openVideoViewer", 1)[0]
    assert "openGroupMemberProfile(" in peer
    assert "onOpenFriendContact: _openContact" in peer


def test_private_display_remark_is_not_used_for_outgoing_avatar_actions():
    source = ROOM.read_text(encoding="utf-8")
    row = source.split("Widget _messageRow", 1)[1].split("Future<void> _forwardMessages", 1)[0]
    assert "_sendNudge(message, displayName)" not in row
    mention = row.split("void appendMentionDraft()", 1)[1].split("// 即时反馈", 1)[0]
    assert "displayName: displayName" not in mention
