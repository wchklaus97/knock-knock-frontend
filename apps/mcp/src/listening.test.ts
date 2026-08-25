import assert from "node:assert/strict";
import test from "node:test";

import {
  LISTENING_HEARTBEAT_MS,
  STAGING_PAIRING_HINT,
  agentAuthFailureMessage,
  listeningRegistrationPath,
  startListeningHeartbeat,
} from "./listening.js";

test("listening heartbeat renews the concrete chat binding inside the 90s window", () => {
  assert.equal(listeningRegistrationPath(), "/v1/agents/me/listener");
  assert.ok(LISTENING_HEARTBEAT_MS < 90_000);
  assert.ok(LISTENING_HEARTBEAT_MS >= 5_000);
});

test("listening heartbeat ticks immediately and can stop", async () => {
  let ticks = 0;
  const handle = startListeningHeartbeat(async () => {
    ticks += 1;
  }, 10_000);
  await new Promise((resolve) => setTimeout(resolve, 20));
  handle.stop();
  assert.equal(ticks, 1);
});

test("invalid agent key stops the heartbeat", async () => {
  let ticks = 0;
  const handle = startListeningHeartbeat(async () => {
    ticks += 1;
    throw new Error("401 /v1/agents/me/asks?claim=false: Invalid agent key");
  }, 10);
  await new Promise((resolve) => setTimeout(resolve, 40));
  handle.stop();
  assert.equal(ticks, 1);
});

test("invalid agent key maps to a pairing hint without echoing the key", () => {
  const message = agentAuthFailureMessage(
    new Error("401 /v1/agents/me/asks?claim=false: {\"error\":{\"code\":\"unauthorized\",\"message\":\"Invalid agent key\"}}"),
  );
  assert.equal(message, STAGING_PAIRING_HINT);
  assert.equal(agentAuthFailureMessage(new Error("409 agent_not_listening")), null);
  assert.doesNotMatch(STAGING_PAIRING_HINT, /vak_/);
});
