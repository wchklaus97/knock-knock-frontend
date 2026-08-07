import assert from "node:assert/strict";
import test from "node:test";
import { looksLikeApnsToken } from "./apns.js";
import { apnsTokensFromDevices } from "./push.js";

test("APNs token filter accepts exactly 64 hexadecimal characters", () => {
  assert.equal(looksLikeApnsToken("a".repeat(64)), true);
  assert.equal(looksLikeApnsToken("ABCDEF0123456789".repeat(4)), true);
  assert.equal(looksLikeApnsToken("dev-00000000-0000-0000-0000-000000000000"), false);
  assert.equal(looksLikeApnsToken("a".repeat(63)), false);
  assert.equal(looksLikeApnsToken("a".repeat(65)), false);
  assert.equal(looksLikeApnsToken("g".repeat(64)), false);
});

test("only physical iOS device tokens are eligible for APNs", () => {
  assert.deepEqual(
    apnsTokensFromDevices([
      { platform: "ios_simulator", push_token: "a".repeat(64) },
      { platform: "ios", push_token: "dev-placeholder" },
      { platform: "ios", push_token: "b".repeat(64) },
      { platform: "ios", push_token: "b".repeat(64) },
      { platform: "android", push_token: "c".repeat(64) },
      { platform: "ios", push_token: null },
    ]),
    ["b".repeat(64)],
  );
});
