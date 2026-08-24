function defineContract({
  tagName,
  rootClass,
  allowedAttributes = [],
  allowedStates = [],
  requiredSlots = [],
  domSignature = []
}) {
  return Object.freeze({
    tagName,
    rootClass,
    allowedAttributes: Object.freeze([...allowedAttributes]),
    allowedStates: Object.freeze([...allowedStates]),
    requiredSlots: Object.freeze([...requiredSlots]),
    domSignature: Object.freeze([...domSignature])
  });
}

export const componentContracts = Object.freeze([
  defineContract({ tagName: "app-status-bar", rootClass: "c-status-bar", allowedAttributes: ["time"], domSignature: [".c-status-bar", ".c-status-bar>.c-status-bar__time", ".c-status-bar>.c-status-bar__indicators"] }),
  defineContract({ tagName: "app-navigation-bar", rootClass: "c-navigation-bar", allowedAttributes: ["title", "leading", "action", "heading"], domSignature: [".c-navigation-bar", ".c-navigation-bar>.c-navigation-bar__leading", ".c-navigation-bar>.c-navigation-bar__title", ".c-navigation-bar>.c-navigation-bar__actions"] }),
  defineContract({ tagName: "app-tab-bar", rootClass: "c-tab-bar", allowedAttributes: ["active"], allowedStates: ["messages", "contacts", "discovery", "profile"], domSignature: [".c-tab-bar", ".c-tab-bar>.c-tab-bar__item"] }),
  defineContract({ tagName: "app-action-button", rootClass: "c-action-button", allowedAttributes: ["kind", "label", "icon", "loading", "disabled", "action"], allowedStates: ["idle", "loading", "disabled"], domSignature: [".c-action-button", ".c-action-button>.c-action-button__icon", ".c-action-button>.c-action-button__label", ".c-action-button>.c-action-button__progress"] }),
  defineContract({ tagName: "app-composer", rootClass: "c-composer", allowedAttributes: ["mode", "placeholder", "disabled"], allowedStates: ["text", "voice", "attachment"], domSignature: [".c-composer", ".c-composer>.c-composer__mode", ".c-composer>.c-composer__field", ".c-composer>.c-composer__send"] }),
  defineContract({ tagName: "app-list-tile", rootClass: "c-list-tile", allowedAttributes: ["title", "subtitle", "leading", "trailing", "disabled", "action"], allowedStates: ["idle", "disabled"], domSignature: [".c-list-tile", ".c-list-tile>.c-list-tile__leading", ".c-list-tile>.c-list-tile__body", ".c-list-tile>.c-list-tile__trailing"] }),
  defineContract({ tagName: "app-avatar", rootClass: "c-avatar", allowedAttributes: ["name", "size", "badge", "image"], allowedStates: ["message", "conversation", "moment", "detail"], domSignature: [".c-avatar", ".c-avatar>.c-avatar__image", ".c-avatar>.c-avatar__fallback", ".c-avatar>.c-avatar__badge"] }),
  defineContract({ tagName: "app-identity-header", rootClass: "c-identity-header", allowedAttributes: ["name", "username", "signature", "image"], domSignature: [".c-identity-header", ".c-identity-header>.c-identity-header__avatar", ".c-identity-header>.c-identity-header__body"] }),
  defineContract({ tagName: "app-contact-index", rootClass: "c-contact-index", allowedAttributes: ["active"], domSignature: [".c-contact-index", ".c-contact-index>.c-contact-index__letter"] }),
  defineContract({ tagName: "app-message-bubble", rootClass: "c-message", allowedAttributes: ["direction", "sender", "content", "delivery", "avatar"], allowedStates: ["sending", "sent", "failed"], domSignature: [".c-message", ".c-message>.c-message__avatar", ".c-message>.c-message__content", ".c-message>.c-message__content>.c-message__row"] }),
  defineContract({ tagName: "app-voice-bubble", rootClass: "c-voice-bubble", allowedAttributes: ["duration", "playback", "direction"], allowedStates: ["idle", "playing", "failed"], domSignature: [".c-voice-bubble", ".c-voice-bubble>.c-voice-bubble__wave", ".c-voice-bubble>.c-voice-bubble__duration"] }),
  defineContract({ tagName: "app-attachment-tile", rootClass: "c-attachment", allowedAttributes: ["name", "meta", "progress", "state"], allowedStates: ["queued", "uploading", "failed", "sent"], domSignature: [".c-attachment", ".c-attachment>.c-attachment__icon", ".c-attachment>.c-attachment__body", ".c-attachment>.c-attachment__action"] }),
  defineContract({ tagName: "app-timestamp", rootClass: "c-timestamp", allowedAttributes: ["label"], domSignature: [".c-timestamp"] }),
  defineContract({ tagName: "app-unread-badge", rootClass: "c-unread-badge", allowedAttributes: ["count", "muted"], domSignature: [".c-unread-badge"] }),
  defineContract({ tagName: "app-status-chip", rootClass: "c-status-chip", allowedAttributes: ["status", "label"], allowedStates: ["processing", "success", "warning", "error"], domSignature: [".c-status-chip", ".c-status-chip>.c-status-chip__icon", ".c-status-chip>.c-status-chip__label"] }),
  defineContract({ tagName: "app-dialog", rootClass: "c-dialog-overlay", allowedAttributes: ["title", "message", "kind", "confirm", "cancel"], allowedStates: ["confirm", "error", "detail", "danger"], domSignature: [".c-dialog-overlay", ".c-dialog-overlay>.c-overlay", ".c-dialog-overlay>.c-overlay>.c-dialog"] }),
  defineContract({ tagName: "app-action-sheet", rootClass: "c-action-sheet-overlay", allowedAttributes: ["title", "options", "selected"], domSignature: [".c-action-sheet-overlay", ".c-action-sheet-overlay>.c-overlay", ".c-action-sheet-overlay>.c-overlay>.c-action-sheet"] }),
  defineContract({ tagName: "app-toast", rootClass: "c-toast", allowedAttributes: ["kind", "message"], allowedStates: ["success", "warning", "error", "info"], domSignature: [".c-toast", ".c-toast>.c-toast__icon", ".c-toast>.c-toast__message"] }),
  defineContract({ tagName: "app-empty-state", rootClass: "c-empty-state", allowedAttributes: ["kind", "title", "message", "action"], allowedStates: ["empty", "permission", "network", "error"], domSignature: [".c-empty-state", ".c-empty-state>.c-empty-state__icon", ".c-empty-state>.c-empty-state__title", ".c-empty-state>.c-empty-state__message"] }),
  defineContract({ tagName: "app-network-capsule", rootClass: "c-network-capsule", allowedAttributes: ["state", "label"], allowedStates: ["offline", "reconnecting", "restored"], domSignature: [".c-network-capsule", ".c-network-capsule>.c-network-capsule__icon", ".c-network-capsule>.c-network-capsule__label"] }),
  defineContract({ tagName: "app-red-packet-card", rootClass: "c-red-packet", allowedAttributes: ["state", "greeting"], allowedStates: ["available", "claimed", "exhausted", "expired", "withdrawn"], domSignature: [".c-red-packet", ".c-red-packet>.c-red-packet__body", ".c-red-packet>.c-red-packet__footer"] }),
  defineContract({ tagName: "app-amount-summary", rootClass: "c-amount-summary", allowedAttributes: ["label", "amount", "asset", "hint"], domSignature: [".c-amount-summary", ".c-amount-summary>.c-amount-summary__label", ".c-amount-summary>.c-amount-summary__value"] }),
  defineContract({ tagName: "app-transaction-row", rootClass: "c-transaction-row", allowedAttributes: ["kind", "title", "subtitle", "amount", "status"], domSignature: [".c-transaction-row", ".c-transaction-row>.c-transaction-row__icon", ".c-transaction-row>.c-transaction-row__body", ".c-transaction-row>.c-transaction-row__amount"] }),
  defineContract({ tagName: "app-moment-tile", rootClass: "c-moment-tile", allowedAttributes: ["author", "content", "location", "time", "state"], allowedStates: ["uploading", "reviewing", "published", "limited", "removed", "failed"], domSignature: [".c-moment-tile", ".c-moment-tile>.c-moment-tile__avatar", ".c-moment-tile>.c-moment-tile__content"] }),
  defineContract({ tagName: "app-moment-grid", rootClass: "c-moment-grid", allowedAttributes: ["count", "failed"], domSignature: [".c-moment-grid", ".c-moment-grid>.c-moment-grid__item"] }),
  defineContract({ tagName: "app-moment-reactions", rootClass: "c-moment-reactions", allowedAttributes: ["likes", "comments"], domSignature: [".c-moment-reactions", ".c-moment-reactions>.c-moment-reactions__likes", ".c-moment-reactions>.c-moment-reactions__comments"] }),
  defineContract({ tagName: "app-visibility-icon", rootClass: "c-visibility-icon", allowedAttributes: ["visibility", "label"], allowedStates: ["public", "friends", "partial", "excluded", "private"], domSignature: [".c-visibility-icon", ".c-visibility-icon>.c-visibility-icon__icon", ".c-visibility-icon>.c-visibility-icon__label"] })
  defineContract({ tagName: "app-nudge-notice", rootClass: "c-nudge-notice", allowedAttributes: ["text"], allowedStates: ["default"] }),
  defineContract({ tagName: "app-contact-tag-management", rootClass: "c-contact-tags", allowedAttributes: ["api"] }),
  defineContract({ tagName: "app-contact-tag-members", rootClass: "c-contact-tag-members", allowedAttributes: ["api", "tag"] }),
  defineContract({ tagName: "app-contact-tag-friend-picker", rootClass: "c-contact-tag-picker", allowedAttributes: ["api", "tag"] }),
]);

export function contractFor(tagName) {
  const contract = componentContracts.find((candidate) => candidate.tagName === tagName);
  if (!contract) throw new Error(`Unknown component contract: ${tagName}`);
  return contract;
}
