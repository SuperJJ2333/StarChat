import test from "node:test";
import assert from "node:assert/strict";
import { getScreen } from "../src/catalog/screens.js";
test("announcement demo exposes mixed images, pending decryption and invalid format", () => {
  for (const state of ["mixed", "decrypting", "malformed"]) {
    assert.equal(getScreen(`chat-announcement-${state}`).state, state);
  }
});