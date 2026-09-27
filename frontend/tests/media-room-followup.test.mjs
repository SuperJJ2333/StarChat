import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";

test("media and room followup demo exposes the approved review states", () => {
  for (const id of ["chat-history-calendar", "chat-history-results",
    "chat-multi-select-active", "chat-announcement-unavailable-admin",
    "moments-timeline-background-upload", "moments-timeline-background-failed",
    "moments-media-video-poster"]) {
    assert.equal(getScreen(id).id, id);
  }
});
