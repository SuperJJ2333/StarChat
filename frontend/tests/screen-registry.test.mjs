import test from "node:test";
import assert from "node:assert/strict";
import { fixtures } from "../src/catalog/fixtures.js";
import { getScreen, screens } from "../src/catalog/screens.js";

const requiredModules = [
  "foundation", "auth", "messages", "chat", "calls", "contacts", "friend",
  "discovery", "moments", "profile", "caibi", "redpacket", "wallet", "feedback"
];

const requiredScreens = [
  "foundation-icons-catalog",
  "auth-login-error-credentials",
  "auth-verification-resend-failed",
  "messages-inbox-sync-failed",
  "chat-room-message-failed",
  "chat-voice-too-short",
  "chat-attachment-permission-denied",
  "calls-video-permission-denied",
  "contacts-index-overlay",
  "friend-delete-confirm",
  "moments-composer-upload-failed",
  "moments-settings-range-sheet",
  "profile-avatar-upload-failed",
  "caibi-transfer-unknown-result",
  "redpacket-detail-concurrent-exhausted",
  "wallet-withdrawal-unknown-result",
  "feedback-type-scale-140",
  "auth-login-default-dark",
  "messages-inbox-default-dark",
  "chat-room-mixed-dark",
  "contacts-index-default-dark",
  "moments-timeline-default-dark",
  "profile-home-default-dark",
  "wallet-home-default-dark"
];

test("registry covers every approved module and representative state", () => {
  assert.ok(screens.length >= 180, `expected at least 180 explicit frames, got ${screens.length}`);
  const modules = new Set(screens.map((screen) => screen.module));
  for (const module of requiredModules) assert.ok(modules.has(module), `missing module ${module}`);
  for (const id of requiredScreens) assert.equal(getScreen(id).id, id);
});

test("screen definitions have stable unique IDs and fixed mobile width", () => {
  const ids = new Set();
  for (const screen of screens) {
    assert.match(screen.id, /^[a-z0-9]+(?:-[a-z0-9]+)*$/u);
    assert.ok(!ids.has(screen.id), `duplicate screen id ${screen.id}`);
    assert.equal(screen.width, 393);
    assert.ok(screen.height >= 852, `${screen.id} is shorter than the device baseline`);
    assert.ok(["light", "dark"].includes(screen.theme));
    assert.ok(screen.title.length > 0);
    assert.ok(screen.tags.length > 0);
    assert.equal(typeof screen.component, "function");
    ids.add(screen.id);
  }
});

test("dark frames are restricted to foundations, components, and approved key screens", () => {
  const darkIds = screens.filter((screen) => screen.theme === "dark").map((screen) => screen.id);
  assert.deepEqual(darkIds.sort(), [
    "auth-login-default-dark",
    "chat-room-mixed-dark",
    "contacts-index-default-dark",
    "foundation-components-catalog-dark",
    "foundation-tokens-overview-dark",
    "messages-inbox-default-dark",
    "moments-timeline-default-dark",
    "profile-home-default-dark",
    "wallet-home-default-dark"
  ].sort());
});

test("financial fixtures preserve fixed precision strings and prohibited features stay absent", () => {
  assert.match(fixtures.finance.caibiBalance, /^\d+\.\d{2}$/u);
  assert.match(fixtures.finance.usdtBalance, /^\d+\.\d{6}$/u);
  assert.equal(fixtures.finance.walletAddress, "TTest...8Demo");
  assert.deepEqual(fixtures.finance.prohibitedFeatures, []);
});
