import { componentContracts } from "../catalog/contracts.js";
import { AppActionButton, AppComposer } from "./actions.js";
import { AppAttachmentTile, AppMessageBubble, AppTimestamp, AppUnreadBadge, AppVoiceBubble } from "./chat.js";
import { AppNavigationBar, AppStatusBar, AppTabBar } from "./chrome.js";
import { AppActionSheet, AppDialog, AppEmptyState, AppNetworkCapsule, AppNudgeNotice, AppStatusChip, AppToast } from "./feedback.js";
import { AppAmountSummary, AppRedPacketCard, AppTransactionRow } from "./finance.js";
import { AppAvatar, AppContactIndex, AppContactTagFriendPicker, AppContactTagManagement, AppContactTagMembers, AppIdentityHeader, AppListTile } from "./identity.js";
import { AppMomentCoverViewer, AppMomentGrid, AppMomentReactions, AppMomentTile, AppMomentsFeedV2, AppVisibilityIcon } from "./moments.js";

const implementations = new Map([
  ["app-status-bar", AppStatusBar],
  ["app-navigation-bar", AppNavigationBar],
  ["app-tab-bar", AppTabBar],
  ["app-action-button", AppActionButton],
  ["app-composer", AppComposer],
  ["app-list-tile", AppListTile],
  ["app-avatar", AppAvatar],
  ["app-identity-header", AppIdentityHeader],
  ["app-contact-index", AppContactIndex],
  ["app-message-bubble", AppMessageBubble],
  ["app-voice-bubble", AppVoiceBubble],
  ["app-attachment-tile", AppAttachmentTile],
  ["app-timestamp", AppTimestamp],
  ["app-unread-badge", AppUnreadBadge],
  ["app-status-chip", AppStatusChip],
  ["app-dialog", AppDialog],
  ["app-action-sheet", AppActionSheet],
  ["app-toast", AppToast],
  ["app-empty-state", AppEmptyState],
  ["app-network-capsule", AppNetworkCapsule],
  ["app-red-packet-card", AppRedPacketCard],
  ["app-amount-summary", AppAmountSummary],
  ["app-transaction-row", AppTransactionRow],
  ["app-moment-tile", AppMomentTile],
  ["app-moment-grid", AppMomentGrid],
  ["app-moment-reactions", AppMomentReactions],
  ["app-visibility-icon", AppVisibilityIcon],
  ["app-nudge-notice", AppNudgeNotice],
  ["app-contact-tag-management", AppContactTagManagement],
  ["app-contact-tag-members", AppContactTagMembers],
  ["app-contact-tag-friend-picker", AppContactTagFriendPicker],
  ["app-moments-feed-v2", AppMomentsFeedV2],
  ["app-moment-cover-viewer", AppMomentCoverViewer]
]);

export function registerComponents() {
  for (const contract of componentContracts) {
    const implementation = implementations.get(contract.tagName);
    if (!implementation) throw new Error(`Missing implementation for ${contract.tagName}`);
    if (!customElements.get(contract.tagName)) customElements.define(contract.tagName, implementation);
  }
}
