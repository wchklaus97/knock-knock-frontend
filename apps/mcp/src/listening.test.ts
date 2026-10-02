import assert from "node:assert/strict";
import { spawn as spawnChildProcess } from "node:child_process";
import { EventEmitter, once } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  INACTIVE_ASK_RETENTION_MS,
  MAX_LOCAL_ASK_CLAIMS,
  SETTLED_ASK_RETENTION_MS,
  beginPhoneAskAnswerRequest,
  getAskClaimStatus,
  hasUnsettledAskClaimForSession,
  listAskClaimStatuses,
  markPhoneAskClaimFailure,
  preparePhoneAskRequest,
  pruneAskClaimState,
  resetAskClaimState,
  settlePhoneAskClaim,
  trackAgentAskResponse,
} from "./ask-claims.js";
import {
  claimAgentAsks,
  readAgentAsks,
} from "./ask-transport.js";
import {
  CODEX_WAKE_PROMPT,
  buildCodexWakeSupervisorInvocation,
  buildCodexWakeEnvironment,
  createCodexWakeRunner as createCodexWakeRunnerBase,
  pendingWakeAsksFromResponse,
  resolveCodexWakeChatId,
  type PendingWakeAsk,
  type SpawnWakeProcess,
} from "./codex-wake-runner.js";
import { runCliListenerLifecycle } from "./cli.js";
import {
  runMcpStdioListeningLifecycle,
  type McpStdioLifecycleTransport,
} from "./index.js";
import {
  LISTENING_HEARTBEAT_MS,
  LISTENING_LEASE_MS,
  LISTENING_RENEW_AFTER_MS,
  STAGING_PAIRING_HINT,
  agentAuthFailureMessage,
  createListeningShutdownController,
  hasActiveLeaseV2Authority,
  listenerRenewalDelayMs,
  listenerReleaseHeaders,
  listeningHeartbeatPath,
  listeningReleasePath,
  listeningRegistrationPath,
  onListenerAuthorityRevoked,
  releaseListeningLease,
  requireActiveLeaseV2Authority,
  requireLeaseV2ForAskWrite,
  safeListeningErrorMessage,
  startListeningHeartbeat,
  type ListeningStatus,
} from "./listening.js";
import {
  sanitizeAgentResponseData,
  sanitizeSensitiveData,
} from "./redaction.js";
import {
  listenerHeaders,
  listenerRenewalBody,
  setListenerLeaseFence,
} from "./thread-binding.js";

const THREAD_ID_A = "123e4567-e89b-12d3-a456-426614174000";
const THREAD_ID_B = "123e4567-e89b-12d3-a456-426614174001";
const TEST_WAKE_CAPABILITY = "A".repeat(43);

const leaseResponse = {
  lease_id: "lease_test_123456789",
  generation: 7,
  renew_after_ms: 30_000,
};

function testWakeCapability() {
  let isClosed = false;
  return {
    brokerUrl: "http://127.0.0.1:43123",
    capability: TEST_WAKE_CAPABILITY,
    expiresAtMs: Date.now() + 60_000,
    close: async () => {
      isClosed = true;
    },
    closed: () => isClosed,
    hasActiveResponse: () => false,
    whenDrained: async (_deadlineMs: number) => "drained" as const,
    settleExternally: () => undefined,
    revoke: () => undefined,
    onTerminal: () => () => undefined,
  };
}

function createCodexWakeRunner(
  options: Parameters<typeof createCodexWakeRunnerBase>[0],
) {
  return createCodexWakeRunnerBase({
    openWakeCapability: async () => testWakeCapability(),
    ...options,
  });
}

const wait = (milliseconds: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

function claimAsk(
  claimToken: string,
  generation = 7,
  ids: { askId?: string; sessionId?: string; turnId?: string } = {},
) {
  return {
    ask_id: ids.askId ?? "ask_phone_0001",
    session_id: ids.sessionId ?? "ses_phone_0001",
    client_turn_id: ids.turnId ?? "turn_phone_0001",
    status: "claimed",
    claim_token: claimToken,
    claim_generation: generation,
    generation,
    listener_generation: generation,
    claim_deadline: new Date(Date.now() + 60_000).toISOString(),
    answerable: true,
    answered_at: null,
    legacy_drain: false,
  };
}

function activeStatus(generation = 7): ListeningStatus {
  return {
    registered: true,
    consumerActive: false,
    fenced: false,
    protocol: "lease-v2",
    generation,
    renewAfterMs: 30_000,
  };
}

test("lease-v2 acquires once, saves its fence, then only renews", async () => {
  const acquisitions: boolean[] = [];
  const renewals: Array<{ lease_id: string; generation: number }> = [];
  const handle = startListeningHeartbeat(
    {
      acquire: async (takeover) => {
        acquisitions.push(takeover);
        return leaseResponse;
      },
      renew: async (lease) => {
        renewals.push(listenerRenewalBody(lease));
        return leaseResponse;
      },
    },
    { intervalMs: 5 },
  );

  await wait(24);
  const statusBeforeStop = handle.status();
  const headersBeforeStop = listenerHeaders();

  assert.deepEqual(acquisitions, [false]);
  assert.ok(renewals.length >= 1);
  assert.deepEqual(renewals[0], {
    lease_id: leaseResponse.lease_id,
    generation: leaseResponse.generation,
  });
  assert.equal(headersBeforeStop["X-Knock-Listener-Lease-ID"], leaseResponse.lease_id);
  assert.equal(headersBeforeStop["X-Knock-Listener-Generation"], "7");
  assert.equal(hasActiveLeaseV2Authority(statusBeforeStop), true);

  handle.stop();
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
});

test("legacy negotiation is explicit drain-only and never consumer-active", async () => {
  const acquisitions: boolean[] = [];
  let renewals = 0;
  const handle = startListeningHeartbeat(
    {
      acquire: async (takeover) => {
        acquisitions.push(takeover);
        return { status: "active", binding_id: "bind_legacy" };
      },
      renew: async () => {
        renewals += 1;
        return leaseResponse;
      },
    },
    { takeover: true, intervalMs: 5 },
  );

  await wait(24);
  handle.setConsumerActive(true);
  const status = handle.status();
  handle.stop();

  assert.ok(acquisitions.length >= 2);
  assert.equal(acquisitions[0], true);
  assert.ok(acquisitions.slice(1).every((takeover) => takeover === false));
  assert.equal(renewals, 0);
  assert.equal(status.protocol, "legacy");
  assert.equal(status.registered, false);
  assert.equal(status.consumerActive, false);
  assert.equal(status.lastError, "legacy_listener_drain_only");
});

test("takeover is consumed only after a successful acquire", async () => {
  const acquisitions: boolean[] = [];
  const originalConsoleError = console.error;
  console.error = () => undefined;
  try {
    const handle = startListeningHeartbeat(
      {
        acquire: async (takeover) => {
          acquisitions.push(takeover);
          if (acquisitions.length === 1) throw new Error("temporary registration failure");
          return leaseResponse;
        },
        renew: async () => leaseResponse,
      },
      { takeover: true, intervalMs: 5 },
    );
    await wait(14);
    handle.stop();
  } finally {
    console.error = originalConsoleError;
  }
  assert.deepEqual(acquisitions, [true, true]);
});

test("lease authority guard fails closed during startup, legacy, mismatch, and fencing", async () => {
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  const startup: ListeningStatus = {
    registered: false,
    consumerActive: false,
    fenced: false,
    protocol: "negotiating",
  };
  assert.throws(() => requireActiveLeaseV2Authority(startup), /authority_required/);
  assert.doesNotThrow(() => requireLeaseV2ForAskWrite(startup, false));
  assert.throws(
    () => requireLeaseV2ForAskWrite(startup, true),
    /authority_required/,
  );

  await wait(0);
  assert.doesNotThrow(() => requireActiveLeaseV2Authority(handle.status()));
  assert.doesNotThrow(() => requireLeaseV2ForAskWrite(handle.status(), true));
  assert.throws(() => requireActiveLeaseV2Authority(activeStatus(8)), /authority_required/);
  assert.throws(
    () =>
      requireActiveLeaseV2Authority({
        ...startup,
        protocol: "legacy",
      }),
    /legacy_listener_drain_only/,
  );
  assert.throws(
    () =>
      requireActiveLeaseV2Authority({
        ...activeStatus(),
        registered: false,
        fenced: true,
      }),
    /lease_fenced/,
  );
  handle.stop();
});

test("lease fencing atomically clears listener headers and all local Ask authority", async () => {
  let rejectRenewal: ((error: Error) => void) | undefined;
  let renewalStartedResolve: (() => void) | undefined;
  const renewalStarted = new Promise<void>((resolve) => {
    renewalStartedResolve = resolve;
  });
  const originalConsoleError = console.error;
  console.error = () => undefined;
  try {
    const handle = startListeningHeartbeat(
      {
        acquire: async () => leaseResponse,
        renew: async () =>
          new Promise<unknown>((_resolve, reject) => {
            rejectRenewal = reject;
            renewalStartedResolve?.();
          }),
      },
      { intervalMs: 5 },
    );
    await wait(2);
    trackAgentAskResponse({ asks: [claimAsk("claim_phone_fence_0001")] });
    assert.equal(getAskClaimStatus("ask_phone_0001")?.phase, "active");
    await renewalStarted;
    rejectRenewal?.(
      new Error('409 heartbeat: {"error":{"code":"lease_fenced"}}'),
    );
    await wait(2);

    assert.equal(handle.status().fenced, true);
    assert.equal(handle.status().registered, false);
    assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
    assert.equal(getAskClaimStatus("ask_phone_0001"), undefined);
    handle.stop();
  } finally {
    console.error = originalConsoleError;
    resetAskClaimState();
    setListenerLeaseFence(null);
  }
});

test("listener stop atomically clears listener headers and local Ask claims", async () => {
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 10_000 },
  );
  await wait(2);
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_stop_0001")] });
  assert.equal(getAskClaimStatus("ask_phone_0001")?.phase, "active");
  handle.stop();
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  assert.equal(getAskClaimStatus("ask_phone_0001"), undefined);
});

test("listener release transport is DELETE-only with an immutable lease fence", async () => {
  const lease = {
    leaseId: leaseResponse.lease_id,
    generation: leaseResponse.generation,
    renewAfterMs: leaseResponse.renew_after_ms,
  };
  const calls: Array<{ path: string; init: RequestInit }> = [];
  await releaseListeningLease(async (requestPath, init) => {
    calls.push({ path: requestPath, init });
    return { released: true };
  }, lease);

  assert.equal(listeningReleasePath(), "/v1/agents/me/listener");
  assert.deepEqual(calls, [
    {
      path: "/v1/agents/me/listener",
      init: {
        method: "DELETE",
        headers: listenerReleaseHeaders(lease),
      },
    },
  ]);
  assert.equal("body" in calls[0].init, false);
});

test("concurrent listener stops share one successful release promise", async () => {
  let resolveRelease: () => void = () => undefined;
  let releaseStartedResolve: () => void = () => undefined;
  const releaseGate = new Promise<void>((resolve) => {
    resolveRelease = resolve;
  });
  const releaseStarted = new Promise<void>((resolve) => {
    releaseStartedResolve = resolve;
  });
  const releasedLeases: unknown[] = [];
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async (lease) => {
        releasedLeases.push(lease);
        releaseStartedResolve();
        await releaseGate;
        return { released: true };
      },
    },
    { intervalMs: 60_000 },
  );
  await wait(0);

  const firstStop = handle.stop();
  const concurrentStop = handle.stop();
  assert.strictEqual(firstStop, concurrentStop);
  await releaseStarted;
  assert.equal(hasActiveLeaseV2Authority(handle.status()), true);
  resolveRelease();
  await firstStop;

  assert.equal(releasedLeases.length, 1);
  assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
});

test("listener release treats lease_fenced as success-equivalent", async () => {
  let releases = 0;
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
        throw new Error('409 release: {"error":{"code":"lease_fenced"}}');
      },
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  await handle.stop();

  assert.equal(releases, 1);
  assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
});

test("transient listener release replays the identical fence once", async () => {
  const releasedLeases: unknown[] = [];
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async (lease) => {
        releasedLeases.push(lease);
        if (releasedLeases.length === 1) {
          throw new Error("503 release temporarily unavailable");
        }
        return { released: true };
      },
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  await handle.stop();

  assert.equal(releasedLeases.length, 2);
  assert.strictEqual(releasedLeases[0], releasedLeases[1]);
  assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
});

test("transient listener release retry cap fails closed with sanitized diagnostics", async () => {
  const releasedLeases: unknown[] = [];
  const diagnostics: string[] = [];
  const originalConsoleError = console.error;
  console.error = (message?: unknown) => diagnostics.push(String(message));
  try {
    const handle = startListeningHeartbeat(
      {
        acquire: async () => leaseResponse,
        renew: async () => leaseResponse,
        release: async (lease) => {
          releasedLeases.push(lease);
          throw new Error(
            "503 release unavailable lease_id=lease_sensitive_123456",
          );
        },
      },
      { intervalMs: 60_000 },
    );
    await wait(0);
    await handle.stop();

    assert.equal(releasedLeases.length, 2);
    assert.strictEqual(releasedLeases[0], releasedLeases[1]);
    assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
    assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
    assert.doesNotMatch(diagnostics.join("\n"), /lease_sensitive/);
  } finally {
    console.error = originalConsoleError;
  }
});

test("listener release auth failure does not retry and still clears local authority", async () => {
  let releases = 0;
  const diagnostics: string[] = [];
  const originalConsoleError = console.error;
  console.error = (message?: unknown) => diagnostics.push(String(message));
  try {
    const handle = startListeningHeartbeat(
      {
        acquire: async () => leaseResponse,
        renew: async () => leaseResponse,
        release: async () => {
          releases += 1;
          throw new Error("401 invalid agent key key=vak_sensitive_release");
        },
      },
      { intervalMs: 60_000 },
    );
    await wait(0);
    await handle.stop();

    assert.equal(releases, 1);
    assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
    assert.doesNotMatch(diagnostics.join("\n"), /vak_sensitive_release/);
  } finally {
    console.error = originalConsoleError;
  }
});

test("listener stop never releases before lease acquisition", async () => {
  let releases = 0;
  const neverAcquired = new Promise<unknown>(() => undefined);
  const handle = startListeningHeartbeat(
    {
      acquire: async () => neverAcquired,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
      },
    },
    { intervalMs: 60_000 },
  );

  await handle.stop();
  assert.equal(releases, 0);
  assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
});

test("stale release completion cannot clear a successor listener", async () => {
  let resolveRelease: () => void = () => undefined;
  let releaseStartedResolve: () => void = () => undefined;
  const releaseGate = new Promise<void>((resolve) => {
    resolveRelease = resolve;
  });
  const releaseStarted = new Promise<void>((resolve) => {
    releaseStartedResolve = resolve;
  });
  const predecessor = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async () => {
        releaseStartedResolve();
        await releaseGate;
      },
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  const predecessorStop = predecessor.stop();
  await releaseStarted;

  const successorLease = {
    lease_id: "lease_successor_123456789",
    generation: 8,
    renew_after_ms: 30_000,
  };
  const successor = startListeningHeartbeat(
    {
      acquire: async () => successorLease,
      renew: async () => successorLease,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  resolveRelease();
  await predecessorStop;

  assert.equal(
    listenerHeaders()["X-Knock-Listener-Lease-ID"],
    successorLease.lease_id,
  );
  assert.equal(hasActiveLeaseV2Authority(successor.status()), true);
  await successor.stop();
});

test("lease cadence follows the backend renew point inside its lease", () => {
  assert.equal(listeningRegistrationPath(), "/v1/agents/me/listener");
  assert.equal(listeningHeartbeatPath(), "/v1/agents/me/listener/heartbeat");
  assert.equal(LISTENING_LEASE_MS, 90_000);
  assert.equal(LISTENING_RENEW_AFTER_MS, 30_000);
  assert.equal(LISTENING_HEARTBEAT_MS, LISTENING_RENEW_AFTER_MS);
  assert.equal(listenerRenewalDelayMs(30_000), 30_000);
  assert.equal(listenerRenewalDelayMs(90_000), 30_000);
  assert.ok(LISTENING_HEARTBEAT_MS < LISTENING_LEASE_MS);
});

test("invalid agent key stops the heartbeat without authority", async () => {
  let acquisitions = 0;
  const originalConsoleError = console.error;
  console.error = () => undefined;
  try {
    const handle = startListeningHeartbeat(
      {
        acquire: async () => {
          acquisitions += 1;
          throw new Error("401 asks: Invalid agent key");
        },
        renew: async () => leaseResponse,
      },
      { intervalMs: 5 },
    );
    await wait(10);
    assert.equal(acquisitions, 1);
    assert.equal(handle.status().registered, false);
    assert.equal(hasActiveLeaseV2Authority(handle.status()), false);
    handle.stop();
  } finally {
    console.error = originalConsoleError;
  }
});

test("invalid agent key maps to a pairing hint without echoing the key", () => {
  const message = agentAuthFailureMessage(
    new Error('401 asks: {"error":{"message":"Invalid agent key"}}'),
  );
  assert.equal(message, STAGING_PAIRING_HINT);
  assert.equal(agentAuthFailureMessage(new Error("409 agent_not_listening")), null);
  assert.doesNotMatch(STAGING_PAIRING_HINT, /vak_/);
});

test("listener errors and recursive output sanitization redact credentials", () => {
  const agentSecret = "vak_super_secret_123456";
  const leaseSecret = "lease_super_secret_123456";
  const claimSecret = "claim_super_secret_123456";
  const sanitized = sanitizeSensitiveData({
    ok: true,
    nested: {
      claim_token: claimSecret,
      lease: { id: leaseSecret },
      api_key: agentSecret,
      authorization: "Bearer private-token",
    },
    list: [{ transcript: "private words" }],
  });
  const exposed = JSON.stringify(sanitized);
  assert.doesNotMatch(exposed, new RegExp(agentSecret));
  assert.doesNotMatch(exposed, new RegExp(leaseSecret));
  assert.doesNotMatch(exposed, new RegExp(claimSecret));
  assert.doesNotMatch(exposed, /private-token|private words/);
  assert.match(exposed, /\[REDACTED\]/);
  assert.doesNotMatch(
    safeListeningErrorMessage(
      new Error(
        `X-Agent-Key=${agentSecret} claim_token=${claimSecret} lease_id=${leaseSecret}`,
      ),
    ),
    new RegExp(`${agentSecret}|${claimSecret}|${leaseSecret}`),
  );
});

test("authorized Ask responses preserve transcript while stripping all credentials", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  const visible = trackAgentAskResponse({
    asks: [
      {
        ...claimAsk("claim_transcript_private_0001"),
        transcript: "Please deploy the staging build",
        context_messages: [
          {
            role: "user",
            transcript: "Earlier private voice context",
            authorization: "Bearer context-private",
          },
        ],
      },
    ],
    lease_id: "lease_response_private_0001",
  }) as { asks: Array<Record<string, unknown>> };

  assert.equal(visible.asks[0].transcript, "Please deploy the staging build");
  assert.deepEqual(visible.asks[0].context_messages, [
    {
      role: "user",
      transcript: "Earlier private voice context",
      authorization: "[REDACTED]",
    },
  ]);
  assert.equal("claim_token" in visible.asks[0], false);
  assert.doesNotMatch(JSON.stringify(visible), /claim_transcript_private|lease_response_private/);

  const diagnostic = JSON.stringify(sanitizeSensitiveData(visible));
  assert.doesNotMatch(diagnostic, /Please deploy|Earlier private/);
  const agentVisible = JSON.stringify(
    sanitizeAgentResponseData({
      transcript: "Agent-visible transcript",
      claim_token: "claim_agent_private",
    }),
  );
  assert.match(agentVisible, /Agent-visible transcript/);
  assert.doesNotMatch(agentVisible, /claim_agent_private/);
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("claim recovery keeps an unanswered same-thread Ask visible on repeated poll", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  const first = trackAgentAskResponse({ asks: [claimAsk("claim_phone_first_0001")] }) as {
    asks: Array<Record<string, unknown>>;
  };
  const repeated = trackAgentAskResponse({ asks: [claimAsk("claim_phone_first_0001")] }) as {
    asks: Array<Record<string, unknown>>;
  };

  assert.equal(first.asks.length, 1);
  assert.equal(repeated.asks[0].ask_id, "ask_phone_0001");
  assert.equal(repeated.asks[0].claim_state, "active");
  assert.equal("claim_token" in repeated.asks[0], false);
  assert.equal(getAskClaimStatus("ask_phone_0001")?.answerInFlight, false);
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("stale claim fails closed and only a complete re-poll tuple recovers it", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_old_0001")] });
  assert.equal(
    markPhoneAskClaimFailure(
      "ses_phone_0001",
      "ask_phone_0001",
      new Error("409 Ask claim is stale, expired, or no longer answerable"),
    ),
    true,
  );
  assert.equal(getAskClaimStatus("ask_phone_0001")?.phase, "recoverable");
  assert.throws(
    () => preparePhoneAskRequest("ses_phone_0001", { status: "running" }),
    /phone_ask_claim_stale/,
  );

  trackAgentAskResponse({ asks: [claimAsk("claim_phone_new_0002")] });
  const recovered = preparePhoneAskRequest("ses_phone_0001", { status: "running" });
  assert.equal(recovered.body.claim_token, "claim_phone_new_0002");
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("claim credentials update atomically and never mix old and partial tuples", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_atomic_old")] });
  trackAgentAskResponse({
    asks: [
      {
        ...claimAsk("claim_phone_atomic_new"),
        claim_deadline: undefined,
      },
    ],
  });
  const status = getAskClaimStatus("ask_phone_0001");
  assert.equal(status?.phase, "recoverable");
  assert.equal(status?.claimGeneration, undefined);
  assert.equal(status?.claimDeadline, undefined);
  assert.throws(
    () => preparePhoneAskRequest("ses_phone_0001", { status: "running" }),
    /phone_ask_claim_incomplete/,
  );
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("answer authority is reserved locally before await and released or settled once", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_answer_0001")] });

  const answer = beginPhoneAskAnswerRequest(
    "ses_phone_0001",
    {
      status: "succeeded",
      in_reply_to_ask_id: "ask_phone_0001",
      idempotency_key: "event-phone-0001",
    },
    "ask_phone_0001",
  );
  assert.equal(answer.body.claim_token, "claim_phone_answer_0001");
  assert.equal(typeof answer.reservationToken, "string");
  assert.equal(getAskClaimStatus("ask_phone_0001")?.answerInFlight, true);
  assert.throws(
    () =>
      beginPhoneAskAnswerRequest(
        "ses_phone_0001",
        { status: "succeeded" },
        "ask_phone_0001",
      ),
    /phone_ask_answer_in_flight/,
  );
  assert.equal(
    markPhoneAskClaimFailure(
      "ses_phone_0001",
      "ask_phone_0001",
      new Error("phone_ask_answer_in_flight"),
    ),
    false,
  );
  settlePhoneAskClaim(
    "ses_phone_0001",
    "ask_phone_0001",
    "competing-reservation",
  );
  assert.equal(getAskClaimStatus("ask_phone_0001")?.answerInFlight, true);

  assert.equal(
    markPhoneAskClaimFailure(
      "ses_phone_0001",
      "ask_phone_0001",
      new Error("temporary network failure"),
      answer.reservationToken,
    ),
    true,
  );
  assert.equal(getAskClaimStatus("ask_phone_0001")?.answerInFlight, false);
  const secondAnswer = beginPhoneAskAnswerRequest(
    "ses_phone_0001",
    { status: "succeeded" },
    "ask_phone_0001",
  );
  settlePhoneAskClaim(
    "ses_phone_0001",
    "ask_phone_0001",
    secondAnswer.reservationToken,
  );
  assert.equal(getAskClaimStatus("ask_phone_0001")?.phase, "settled");
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("phone Ask progress and answer preparation fail after lease authority is cleared", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_closed_0001")] });
  setListenerLeaseFence(null);
  assert.throws(
    () =>
      preparePhoneAskRequest(
        "ses_phone_0001",
        { status: "running" },
        "ask_phone_0001",
      ),
    /generation_mismatch/,
  );

  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_phone_closed_0002")] });
  setListenerLeaseFence(null);
  assert.throws(
    () =>
      beginPhoneAskAnswerRequest(
        "ses_phone_0001",
        { status: "succeeded" },
        "ask_phone_0001",
      ),
    /generation_mismatch/,
  );
  resetAskClaimState();
});

test("only Ask-bearing writes require lease authority; generic writes stay compatible", async () => {
  resetAskClaimState();
  setListenerLeaseFence(null);
  assert.equal(hasUnsettledAskClaimForSession("ses_generic"), false);
  assert.doesNotThrow(() => requireLeaseV2ForAskWrite(undefined, false));
  assert.throws(
    () => requireLeaseV2ForAskWrite(undefined, true),
    /authority_required|listener_authority_revoked/,
  );

  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  trackAgentAskResponse({ asks: [claimAsk("claim_write_gate_0001")] });
  assert.equal(hasUnsettledAskClaimForSession("ses_phone_0001"), true);
  assert.doesNotThrow(() =>
    requireLeaseV2ForAskWrite(handle.status(), true),
  );
  resetAskClaimState();
  handle.stop();
});

test("Ask read and claim transports use exact method/path separation", async () => {
  const calls: Array<{
    path: string;
    init: RequestInit & { json?: unknown; timeoutMs?: number };
  }> = [];
  await readAgentAsks(
    async (path, init) => {
      calls.push({ path, init });
      return { asks: [] };
    },
    { timeoutMs: 5_000 },
  );
  await readAgentAsks(
    async (path, init) => {
      calls.push({ path, init });
      return { asks: [] };
    },
    { waitMs: 1_250 },
  );
  await claimAgentAsks(
    async (path, init) => {
      calls.push({ path, init });
      return { asks: [], binding: {} };
    },
    { timeoutMs: 5_000 },
  );
  assert.deepEqual(calls, [
    {
      path: "/v1/agents/me/asks",
      init: { method: "GET", timeoutMs: 5_000 },
    },
    {
      path: "/v1/agents/me/asks?wait_ms=1250",
      init: { method: "GET" },
    },
    {
      path: "/v1/agents/me/asks/claim",
      init: {
        method: "POST",
        timeoutMs: 5_000,
      },
    },
  ]);
  assert.ok(calls.every(({ path }) => !/[?&]claim=/.test(path)));
});

test("passive wake observation is GET-only and cannot mutate Ask claims", async () => {
  let mutationAttempted = false;
  const response = await readAgentAsks<{ asks: unknown[] }>(
    async (path, init) => {
      mutationAttempted =
        init.method !== "GET" ||
        Object.prototype.hasOwnProperty.call(init, "json") ||
        path.includes("/claim") ||
        /[?&]claim=/.test(path);
      return {
        asks: [
          {
            ask_id: "ask_passive",
            client_turn_id: "turn_passive",
            status: "pending",
            transcript: "private passive transcript",
            answerable: true,
          },
        ],
      };
    },
    { timeoutMs: 5_000 },
  );
  const wakeState = pendingWakeAsksFromResponse(response);
  assert.equal(mutationAttempted, false);
  assert.equal(wakeState[0].askId, "ask_passive");
  assert.doesNotMatch(JSON.stringify(wakeState), /private passive transcript/);
});

test("claim POST grants internal answer authority but external output hides credentials", async () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  const response = await claimAgentAsks<{
    asks: Array<Record<string, unknown>>;
    binding: Record<string, unknown>;
  }>(
    async (path, init) => {
      assert.equal(path, "/v1/agents/me/asks/claim");
      assert.equal(init.method, "POST");
      return {
        asks: [
          {
            ...claimAsk("claim_post_authority_0001"),
            transcript: "Deploy through the claimed MCP Ask",
          },
        ],
        binding: {
          lease_id: "lease_binding_private_0001",
          generation: 7,
        },
      };
    },
  );
  const agentOutput = trackAgentAskResponse(response) as {
    asks: Array<Record<string, unknown>>;
  };
  assert.equal(
    agentOutput.asks[0].transcript,
    "Deploy through the claimed MCP Ask",
  );
  assert.equal("claim_token" in agentOutput.asks[0], false);
  const prepared = preparePhoneAskRequest(
    "ses_phone_0001",
    { status: "running" },
    "ask_phone_0001",
  );
  assert.equal(prepared.body.claim_token, "claim_post_authority_0001");

  const cliDiagnostic = JSON.stringify(sanitizeSensitiveData(response));
  assert.doesNotMatch(cliDiagnostic, /claim_post_authority|lease_binding_private/);
  assert.doesNotMatch(cliDiagnostic, /Deploy through the claimed MCP Ask/);
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("legacy Ask is visible for drain but cannot mint answer authority", () => {
  resetAskClaimState();
  const visible = trackAgentAskResponse({
    asks: [
      {
        ask_id: "ask_legacy_0001",
        session_id: "ses_legacy_0001",
        status: "claimed",
        claim_token: null,
        claim_generation: null,
        legacy_drain: true,
        answerable: false,
      },
    ],
  }) as { asks: Array<Record<string, unknown>> };

  assert.equal(visible.asks[0].claim_state, "legacy-drain");
  assert.equal("claim_token" in visible.asks[0], false);
  assert.throws(
    () => preparePhoneAskRequest("ses_legacy_0001", { status: "succeeded" }),
    /legacy_ask_drain/,
  );
  resetAskClaimState();
});

test("local Ask state is bounded and evicts expired and settled entries", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: 7,
    renewAfterMs: 30_000,
  });
  for (let index = 0; index <= MAX_LOCAL_ASK_CLAIMS; index += 1) {
    const suffix = String(index).padStart(4, "0");
    trackAgentAskResponse({
      asks: [
        claimAsk(`claim_bounded_${suffix}`, 7, {
          askId: `ask_bounded_${suffix}`,
          sessionId: `ses_bounded_${suffix}`,
          turnId: `turn_bounded_${suffix}`,
        }),
      ],
    });
  }
  assert.equal(listAskClaimStatuses().length, MAX_LOCAL_ASK_CLAIMS);
  assert.equal(getAskClaimStatus("ask_bounded_0000"), undefined);

  const settledId = `ask_bounded_${String(MAX_LOCAL_ASK_CLAIMS).padStart(4, "0")}`;
  const settledSessionId =
    `ses_bounded_${String(MAX_LOCAL_ASK_CLAIMS).padStart(4, "0")}`;
  const settlement = beginPhoneAskAnswerRequest(
    settledSessionId,
    { status: "succeeded" },
    settledId,
  );
  settlePhoneAskClaim(
    settledSessionId,
    settledId,
    settlement.reservationToken,
  );
  pruneAskClaimState(Date.now() + SETTLED_ASK_RETENTION_MS + 1);
  assert.equal(getAskClaimStatus(settledId), undefined);

  resetAskClaimState();
  const expired = claimAsk("claim_expiring_0001");
  expired.claim_deadline = new Date(Date.now() + 1_000).toISOString();
  trackAgentAskResponse({ asks: [expired] });
  const deadline = Date.parse(expired.claim_deadline);
  pruneAskClaimState(deadline + 1);
  assert.equal(getAskClaimStatus("ask_phone_0001")?.phase, "recoverable");
  assert.equal(getAskClaimStatus("ask_phone_0001")?.claimGeneration, undefined);
  pruneAskClaimState(deadline + INACTIVE_ASK_RETENTION_MS + 1);
  assert.equal(getAskClaimStatus("ask_phone_0001"), undefined);
  resetAskClaimState();
  setListenerLeaseFence(null);
});

class FakeWakeChild extends EventEmitter {
  readonly signals: NodeJS.Signals[] = [];

  constructor(readonly pid?: number) {
    super();
  }

  kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
    this.signals.push(signal);
    return true;
  }
}

function wakeAsk(
  askId: string,
  revision = "pending-v1",
  overrides: Partial<PendingWakeAsk> = {},
): PendingWakeAsk {
  return {
    askId,
    clientTurnId: `turn_${askId}`,
    revision,
    wakeable: true,
    ...overrides,
  };
}

test("wake polling preserves Ask identity and excludes settled and legacy drain", () => {
  const pending = pendingWakeAsksFromResponse({
    asks: [
      {
        ask_id: "ask_a",
        client_turn_id: "turn_a",
        status: "pending",
        answerable: true,
        legacy_drain: false,
        transcript: "must not enter wake state",
        claim_token: "claim_private_0001",
      },
      {
        ask_id: "ask_legacy",
        status: "pending",
        answerable: false,
        legacy_drain: true,
      },
      {
        ask_id: "ask_done",
        status: "answered",
        answered_at: "2026-08-27T00:00:00Z",
      },
    ],
  });
  assert.deepEqual(
    pending.map(({ askId, legacyDrain, wakeable, terminal }) => ({
      askId,
      legacyDrain,
      wakeable,
      terminal,
    })),
    [
      {
        askId: "ask_a",
        legacyDrain: false,
        wakeable: true,
        terminal: false,
      },
      {
        askId: "ask_legacy",
        legacyDrain: true,
        wakeable: false,
        terminal: false,
      },
      {
        askId: "ask_done",
        legacyDrain: false,
        wakeable: false,
        terminal: true,
      },
    ],
  );
  assert.doesNotMatch(JSON.stringify(pending), /transcript|claim_private/);
});

test("wake runner uses fixed resume argv and a strict secret-free environment", async (t) => {
  const envDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-wake-env-"));
  const agentEnvPath = path.join(envDirectory, "custom-staging-agent.env");
  fs.writeFileSync(agentEnvPath, "BRIDGE_AGENT_KEY=never-forward-this-value\n");
  t.after(() => fs.rmSync(envDirectory, { recursive: true, force: true }));
  const children: FakeWakeChild[] = [];
  const calls: Array<{
    command: string;
    args: readonly string[];
    stdio: string;
    env: NodeJS.ProcessEnv;
    detached: boolean;
  }> = [];
  const spawnProcess: SpawnWakeProcess = (command, args, options) => {
    calls.push({
      command,
      args,
      stdio: options.stdio,
      env: options.env,
      detached: options.detached,
    });
    const child = new FakeWakeChild();
    children.push(child);
    queueMicrotask(() => child.emit("spawn"));
    return child;
  };
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [wakeAsk("ask_one"), wakeAsk("ask_two")],
    spawnProcess,
    parentEnv: {
      PATH: "/usr/bin",
      HOME: "/Users/test",
      SHELL: "/bin/zsh",
      CODEX_HOME: "/Users/test/.codex",
      KNOCK_KNOCK_API_URL:
        "https://knock-knock-backend-staging.wch-klaus.workers.dev///",
      BRIDGE_API_URL: "http://wrong.example.test",
      KNOCK_KNOCK_AGENT_ENV: ".env.agent.staging",
      KNOCK_KNOCK_LISTENER_LEASE_ID: "lease_parent_stale",
      KNOCK_KNOCK_LISTENER_GENERATION: "999",
      KNOCK_KNOCK_AGENT_KEY: "vak_parent_secret",
      BRIDGE_AGENT_KEY: "vak_bridge_secret",
      OPENAI_API_KEY: "sk-parent-secret",
      TRANSCRIPT: "private transcript",
      ARBITRARY_PARENT_SECRET: "do-not-copy",
    },
    platform: "darwin",
    logger: () => undefined,
  });

  runner.start();
  await wait(5);
  await Promise.all([runner.pollNow(), runner.pollNow(), runner.pollNow()]);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "codex");
  assert.deepEqual(calls[0].args, [
    "exec",
    "resume",
    "--all",
    THREAD_ID_A,
    CODEX_WAKE_PROMPT,
  ]);
  assert.equal(calls[0].stdio, "ignore");
  assert.equal(calls[0].detached, true);
  assert.deepEqual(calls[0].env, {
    PATH: "/usr/bin",
    HOME: "/Users/test",
    SHELL: "/bin/zsh",
    CODEX_HOME: "/Users/test/.codex",
    CODEX_THREAD_ID: THREAD_ID_A,
    KNOCK_KNOCK_WAKE_BROKER_URL: "http://127.0.0.1:43123",
    KNOCK_KNOCK_WAKE_CAPABILITY: TEST_WAKE_CAPABILITY,
  });
  assert.equal(calls[0].env.KNOCK_KNOCK_AGENT_KEY, undefined);
  assert.equal(calls[0].env.BRIDGE_AGENT_KEY, undefined);
  assert.equal(calls[0].env.KNOCK_KNOCK_AGENT_ENV, undefined);
  assert.equal(calls[0].env.KNOCK_KNOCK_LISTENER_LEASE_ID, undefined);
  assert.equal(calls[0].env.KNOCK_KNOCK_LISTENER_GENERATION, undefined);
  assert.doesNotMatch(
    JSON.stringify({ args: calls[0].args, env: calls[0].env }),
    new RegExp(`${leaseResponse.lease_id}|${agentEnvPath}|vak_parent_secret|sk-parent-secret`),
  );
  assert.deepEqual(runner.snapshot(), { state: "working", askCount: 2 });
  runner.stop();
  assert.deepEqual(children[0].signals, ["SIGTERM"]);
  children[0].emit("close", null, "SIGTERM");
});

test("environment builder copies only Codex runtime identity and a local capability", () => {
  const env = buildCodexWakeEnvironment(THREAD_ID_A, {
    PATH: "/bin",
    LANG: "en_US.UTF-8",
    KNOCK_KNOCK_API_URL: "https://staging.example.test/",
    KNOCK_KNOCK_AGENT_ENV: "../unsafe/.env.agent.staging",
    KNOCK_KNOCK_AGENT_KEY: "secret-a",
    API_TOKEN: "secret-b",
    AUTHORIZATION: "Bearer secret-c",
    transcript: "secret-d",
    UNRELATED: "secret-e",
  }, testWakeCapability());
  assert.deepEqual(env, {
    PATH: "/bin",
    LANG: "en_US.UTF-8",
    CODEX_THREAD_ID: THREAD_ID_A,
    KNOCK_KNOCK_WAKE_BROKER_URL: "http://127.0.0.1:43123",
    KNOCK_KNOCK_WAKE_CAPABILITY: TEST_WAKE_CAPABILITY,
  });
});

test("fatal wake capability failure stops its parent listener lease exactly once", async () => {
  let releases = 0;
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
        return { released: true };
      },
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), true);

  let runner: ReturnType<typeof createCodexWakeRunner> | undefined;
  let stopPromise: Promise<void> | undefined;
  let fatalNotifications = 0;
  let shutdowns = 0;
  const stop = (): Promise<void> => {
    if (stopPromise) return stopPromise;
    shutdowns += 1;
    runner?.stop();
    stopPromise = heartbeat.stop();
    return stopPromise;
  };
  runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [wakeAsk("ask_capability_failure")],
    openWakeCapability: async () => {
      throw new Error("wake capability unavailable");
    },
    onFatal: () => {
      fatalNotifications += 1;
      void stop();
    },
    logger: () => undefined,
  });

  await runner.pollNow();
  await stop();
  assert.deepEqual(runner.snapshot(), { state: "fenced", askCount: 0 });
  assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), false);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  runner.revoke();
  stop();
  assert.equal(fatalNotifications, 1);
  assert.equal(shutdowns, 1);
  assert.equal(releases, 1);
});

test("listener lease revocation fences its wake runner exactly once", async () => {
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);

  let runner: ReturnType<typeof createCodexWakeRunner> | undefined;
  let unsubscribeRevocation = () => undefined;
  let fatalNotifications = 0;
  let shutdowns = 0;
  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    shutdowns += 1;
    unsubscribeRevocation();
    runner?.stop();
    heartbeat.stop();
  };
  runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [],
    onFatal: () => {
      fatalNotifications += 1;
      stop();
    },
    logger: () => undefined,
  });
  unsubscribeRevocation = onListenerAuthorityRevoked(() => {
    runner?.revoke();
    stop();
  });

  heartbeat.stop();
  assert.deepEqual(runner.snapshot(), { state: "fenced", askCount: 0 });
  runner.revoke();
  stop();
  assert.equal(fatalNotifications, 1);
  assert.equal(shutdowns, 1);
});

test("wake suppression survives status revisions, temporary hiding, and child lifetime", async (t) => {
  let observations = [wakeAsk("ask_same", "revision-1")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  observations = [];
  await runner.pollNow();
  observations = [wakeAsk("ask_same", "claimed-revision-2")];
  await runner.pollNow();
  children[0].emit("exit", 0, null);
  await wait(3);
  observations = [];
  await runner.pollNow();
  observations = [wakeAsk("ask_same", "pending-revision-3")];
  await runner.pollNow();
  assert.equal(children.length, 1);

  observations = [
    wakeAsk("ask_same", "new-turn-revision", {
      clientTurnId: "turn_new_identity",
    }),
  ];
  await runner.pollNow();
  assert.equal(children.length, 1);

  observations = [wakeAsk("ask_genuinely_new", "pending-v1")];
  await runner.pollNow();
  assert.equal(children.length, 2);
  runner.stop();
});

test("a first positive claim generation rearms a successful-unsettled wake", async (t) => {
  let observations = [
    wakeAsk("ask_generation", "generation-unknown"),
  ];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 1,
    platform: "win32",
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  assert.equal(children.length, 1);
  children[0].emit("exit", 0, null);

  observations = [
    wakeAsk("ask_generation", "generation-1", { authorityGeneration: 1 }),
  ];
  await runner.pollNow();
  assert.equal(children.length, 2);
  await Promise.all([runner.pollNow(), runner.pollNow()]);
  assert.equal(children.length, 2);

  children[1].emit("exit", 0, null);
  await runner.pollNow();
  assert.equal(children.length, 2);

  observations = [
    wakeAsk("ask_generation", "generation-2", { authorityGeneration: 2 }),
  ];
  await runner.pollNow();
  assert.equal(children.length, 3);
});

test("a first positive claim generation rearms an exhausted wake", async (t) => {
  let clock = 10_000;
  let observations = [wakeAsk("ask_generation_exhausted", "generation-unknown")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 1,
    now: () => clock,
    platform: "win32",
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  children[0].emit("exit", 75, null);
  observations = [
    wakeAsk("ask_generation_exhausted", "generation-1", {
      authorityGeneration: 1,
    }),
  ];
  await runner.pollNow();
  assert.equal(children.length, 2);
  clock += 60_000;
  await runner.pollNow();
  assert.equal(children.length, 2);
});

test("advancing authority fences an active stale wake and preserves only the newest generation", async (t) => {
  let observations = [
    wakeAsk("ask_active_generation", "generation-1", {
      authorityGeneration: 1,
    }),
  ];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 1,
    childKillGraceMs: 50,
    platform: "win32",
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  observations = [
    wakeAsk("ask_active_generation", "generation-2", {
      authorityGeneration: 2,
    }),
  ];
  await runner.pollNow();
  assert.deepEqual(children[0].signals, ["SIGTERM"]);
  assert.equal(children.length, 1);

  observations = [
    wakeAsk("ask_active_generation", "generation-3", {
      authorityGeneration: 3,
    }),
  ];
  await runner.pollNow();
  assert.deepEqual(children[0].signals, ["SIGTERM"]);
  children[0].emit("exit", 0, null);
  await runner.pollNow();
  assert.equal(children.length, 2);

  children[0].emit("close", 0, null);
  children[0].emit("error", new Error("late stale callback"));
  await Promise.all([runner.pollNow(), runner.pollNow()]);
  assert.equal(children.length, 2);
});

test("same poll count with a different Ask ID wakes the new Ask", async () => {
  let observations = [wakeAsk("ask_first")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });

  await runner.pollNow();
  observations = [wakeAsk("ask_second")];
  children[0].emit("exit", 0, null);
  await wait(3);
  assert.equal(children.length, 2);
  runner.stop();
});

test("legacy drain observations never wake Codex", async () => {
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [
      wakeAsk("ask_legacy", "legacy-v1", {
        legacyDrain: true,
        wakeable: false,
      }),
    ],
    spawnProcess: (() => {
      throw new Error("legacy drain must not spawn");
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  await runner.pollNow();
  assert.deepEqual(runner.snapshot(), { state: "idle", askCount: 0 });
  runner.stop();
});

test("failed wakes use per-Ask cooldown and stop at the retry cap", async (t) => {
  let clock = 10_000;
  let observations = [wakeAsk("ask_retry", "pending-revision")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 2,
    now: () => clock,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  children[0].emit("exit", 75, null);
  await wait(2);
  await runner.pollNow();
  assert.equal(children.length, 1);

  clock += 2_001;
  observations = [wakeAsk("ask_retry", "claimed-revision")];
  await runner.pollNow();
  assert.equal(children.length, 2);
  children[1].emit("exit", 75, null);
  await wait(2);
  clock += 30_001;
  observations = [wakeAsk("ask_retry", "pending-again-revision")];
  await runner.pollNow();
  assert.equal(children.length, 2);
  runner.stop();
});

test("poll failures obey exponential backoff before consuming another poll", async () => {
  let clock = 0;
  let polls = 0;
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    now: () => clock,
    pollPending: async () => {
      polls += 1;
      if (polls <= 2) throw new Error("temporary poll failure");
      return [];
    },
    logger: () => undefined,
  });

  await runner.pollNow();
  assert.equal(polls, 1);
  await runner.pollNow();
  assert.equal(polls, 1);
  clock = 2_000;
  await runner.pollNow();
  assert.equal(polls, 2);
  clock = 5_999;
  await runner.pollNow();
  assert.equal(polls, 2);
  clock = 6_000;
  await runner.pollNow();
  assert.equal(polls, 3);
  runner.stop();
});

test("wake child timeout TERM/KILLs its stable supervisor and remains fenced until close", async () => {
  const child = new FakeWakeChild(4242);
  let fatalNotifications = 0;
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [wakeAsk("ask_timeout")],
    childTimeoutMs: 8,
    childKillGraceMs: 5,
    spawnProcess: (() => {
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    platform: "darwin",
    onFatal: () => {
      fatalNotifications += 1;
    },
    logger: () => undefined,
  });

  await runner.pollNow();
  await wait(20);
  assert.deepEqual(child.signals, ["SIGTERM", "SIGKILL"]);
  assert.equal(runner.snapshot().state, "fenced");
  assert.equal(fatalNotifications, 1);
  runner.revoke();
  assert.equal(fatalNotifications, 1);
  child.emit("close", null, "SIGKILL");
  assert.equal(runner.snapshot().state, "fenced");
  runner.stop();
});

test("wake drain rejection fails closed into supervisor termination", async () => {
  const child = new FakeWakeChild(4243);
  let capabilityCloses = 0;
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [wakeAsk("ask_rejected_drain")],
    childTimeoutMs: 60_000,
    childKillGraceMs: 5,
    brokerDrainTimeoutMs: 5,
    spawnProcess: (() => {
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    platform: "darwin",
    openWakeCapability: async () => ({
      ...testWakeCapability(),
      close: async () => {
        capabilityCloses += 1;
      },
      hasActiveResponse: () => true,
      whenDrained: async () => {
        throw new Error("synthetic drain failure");
      },
    }),
    logger: () => undefined,
  });

  await runner.pollNow();
  runner.revoke();
  await wait(0);
  assert.deepEqual(child.signals, ["SIGTERM"]);
  await wait(8);
  assert.deepEqual(child.signals, ["SIGTERM", "SIGKILL"]);
  assert.equal(capabilityCloses, 1);
  child.emit("close", null, "SIGKILL");
  runner.stop();
});

test(
  "owned sentinel drains a TERM-resistant descendant before reporting leader exit",
  { skip: process.platform === "win32" },
  async (t) => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-supervisor-"));
    const markerPath = path.join(directory, "descendant.marker");
    const pidPath = path.join(directory, "descendant.pid");
    const descendantSource = String.raw`
      const fs = require("node:fs");
      const markerPath = process.argv[1];
      process.on("SIGTERM", () => fs.appendFileSync(markerPath, "term\n"));
      fs.writeFileSync(markerPath, "ready\n");
      setInterval(() => undefined, 1000);
    `;
    const leaderSource = String.raw`
      const { spawn } = require("node:child_process");
      const fs = require("node:fs");
      const [descendantSource, markerPath, pidPath] = process.argv.slice(1);
      const descendant = spawn(
        process.execPath,
        ["-e", descendantSource, markerPath],
        { stdio: "ignore" },
      );
      fs.writeFileSync(pidPath, String(descendant.pid));
      descendant.unref();
      const finishWhenReady = () => {
        if (fs.existsSync(markerPath)) process.exit(0);
        setTimeout(finishWhenReady, 1);
      };
      finishWhenReady();
    `;
    const invocation = buildCodexWakeSupervisorInvocation(
      process.execPath,
      ["-e", leaderSource, descendantSource, markerPath, pidPath],
      100,
    );
    const supervisor = spawnChildProcess(
      invocation.command,
      [...invocation.args],
      { stdio: "ignore" },
    );
    t.after(() => {
      if (supervisor.exitCode === null && supervisor.signalCode === null) {
        supervisor.kill("SIGKILL");
      }
      fs.rmSync(directory, { recursive: true, force: true });
    });

    const [code, signal] = await Promise.race([
      once(supervisor, "close") as Promise<
        [number | null, NodeJS.Signals | null]
      >,
      wait(2_000).then(() => {
        throw new Error("wake supervisor did not drain");
      }),
    ]);
    assert.equal(code, 0);
    assert.equal(signal, null);
    assert.match(fs.readFileSync(markerPath, "utf8"), /ready\nterm\n/);
    const descendantPid = Number(fs.readFileSync(pidPath, "utf8"));
    let descendantExists = true;
    try {
      process.kill(descendantPid, 0);
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
      descendantExists = false;
    }
    assert.equal(descendantExists, false);
  },
);

test(
  "owned supervisor closes after leader spawn failure",
  { skip: process.platform === "win32" },
  async (t) => {
    const invocation = buildCodexWakeSupervisorInvocation(
      path.join(os.tmpdir(), `vab-missing-leader-${process.pid}-${Date.now()}`),
      [],
      20,
    );
    const supervisor = spawnChildProcess(
      invocation.command,
      [...invocation.args],
      { stdio: "ignore" },
    );
    t.after(() => {
      if (supervisor.exitCode === null && supervisor.signalCode === null) {
        supervisor.kill("SIGKILL");
      }
    });

    const [code, signal] = await Promise.race([
      once(supervisor, "close") as Promise<
        [number | null, NodeJS.Signals | null]
      >,
      wait(2_000).then(() => {
        throw new Error("wake supervisor did not close after leader spawn failure");
      }),
    ]);
    assert.equal(code, 1);
    assert.equal(signal, null);
  },
);

test("supervisor disappearance cancels escalation before numeric PID reuse", async () => {
  const owners = new Map<number, FakeWakeChild>();
  class ReusablePidSupervisor extends FakeWakeChild {
    override kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
      const owner = this.pid === undefined ? undefined : owners.get(this.pid);
      if (!owner) return false;
      owner.signals.push(signal);
      return true;
    }
  }

  const supervisor = new ReusablePidSupervisor(4444);
  owners.set(4444, supervisor);
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => [wakeAsk("ask_reused_supervisor")],
    childKillGraceMs: 5,
    spawnProcess: (() => {
      queueMicrotask(() => supervisor.emit("spawn"));
      return supervisor;
    }) as SpawnWakeProcess,
    platform: "darwin",
    logger: () => undefined,
  });

  await runner.pollNow();
  runner.stop();
  assert.deepEqual(supervisor.signals, ["SIGTERM"]);
  supervisor.emit("exit", null, "SIGTERM");
  const unrelatedProcess = new FakeWakeChild(4444);
  owners.set(4444, unrelatedProcess);
  await wait(8);
  assert.deepEqual(supervisor.signals, ["SIGTERM"]);
  assert.deepEqual(unrelatedProcess.signals, []);
  supervisor.emit("close", null, "SIGTERM");
});

test("wake runner stop TERM/KILL-cleans its child and prevents later work", async () => {
  let polls = 0;
  let spawns = 0;
  const child = new FakeWakeChild();
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => {
      polls += 1;
      return [wakeAsk("ask_stop")];
    },
    childKillGraceMs: 5,
    platform: "win32",
    spawnProcess: (() => {
      spawns += 1;
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });

  runner.start();
  await wait(4);
  runner.stop();
  const pollsAtStop = polls;
  await wait(8);
  await runner.pollNow();
  assert.deepEqual(child.signals, ["SIGTERM", "SIGKILL"]);
  assert.equal(polls, pollsAtStop);
  assert.equal(spawns, 1);
  assert.deepEqual(runner.snapshot(), { state: "fenced", askCount: 0 });
  child.emit("close", null, "SIGKILL");
});

test("wake state and logs never retain poll errors or sensitive Ask content", async () => {
  const logs: string[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID_A,
    pollPending: async () => {
      throw new Error(
        "lease_fenced transcript=private claim_token=claim_private lease_id=lease_private key=vak_private",
      );
    },
    logger: (message) => logs.push(message),
  });

  runner.start();
  await wait(5);
  const exposed = `${JSON.stringify(runner.snapshot())}\n${logs.join("\n")}\n${CODEX_WAKE_PROMPT}`;
  assert.deepEqual(Object.keys(runner.snapshot()).sort(), ["askCount", "state"]);
  assert.equal(runner.snapshot().state, "fenced");
  assert.doesNotMatch(exposed, /private|vak_/);
  runner.stop();
});

test("wake chat id rejects option-like and non-UUID Codex thread IDs", () => {
  assert.equal(resolveCodexWakeChatId({ CODEX_THREAD_ID: THREAD_ID_A }), THREAD_ID_A);
  assert.equal(
    resolveCodexWakeChatId({ KNOCK_KNOCK_CHAT_ID: THREAD_ID_B }),
    THREAD_ID_B,
  );
  assert.throws(() => resolveCodexWakeChatId({}), /UUID-like/);
  assert.throws(
    () => resolveCodexWakeChatId({ CODEX_THREAD_ID: "--help" }),
    /must not start/,
  );
  assert.throws(
    () => resolveCodexWakeChatId({ CODEX_THREAD_ID: "chat_not_a_uuid" }),
    /UUID-like/,
  );
});

test("stdio MCP signal, EOF, and transport close share one bounded release", async () => {
  let releases = 0;
  let releaseNow: () => void = () => undefined;
  const releaseGate = new Promise<void>((resolve) => {
    releaseNow = resolve;
  });
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
        await releaseGate;
        return { released: true };
      },
    },
    { intervalMs: 60_000, releaseAttemptTimeoutMs: 1_000 },
  );
  await wait(0);
  const processEvents = new EventEmitter();
  const inputEvents = new EventEmitter();
  const transport: McpStdioLifecycleTransport = {};
  let closes = 0;
  const running = runMcpStdioListeningLifecycle({
    heartbeat,
    transport,
    processEvents,
    inputEvents,
    close: async () => {
      closes += 1;
      transport.onclose?.();
    },
    onError: () => undefined,
  });

  processEvents.emit("SIGTERM");
  processEvents.emit("SIGINT");
  inputEvents.emit("end");
  inputEvents.emit("close");
  transport.onclose?.();
  await wait(0);
  assert.equal(releases, 1);
  assert.equal(closes, 0);
  assert.equal(processEvents.listenerCount("SIGINT"), 0);
  assert.equal(processEvents.listenerCount("SIGTERM"), 0);
  assert.equal(inputEvents.listenerCount("end"), 0);
  assert.equal(inputEvents.listenerCount("close"), 0);

  releaseNow();
  await running;
  assert.equal(releases, 1);
  assert.equal(closes, 1);
  assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), false);
});

test("vab listen signal and EOF stops are concurrent and idempotent", async () => {
  let releases = 0;
  let releaseNow: () => void = () => undefined;
  const releaseGate = new Promise<void>((resolve) => {
    releaseNow = resolve;
  });
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
        await releaseGate;
      },
    },
    { intervalMs: 60_000, releaseAttemptTimeoutMs: 1_000 },
  );
  await wait(0);
  const processEvents = new EventEmitter();
  const inputEvents = new EventEmitter();
  const running = runCliListenerLifecycle(
    heartbeat,
    (shutdown) => shutdown.wait(),
    { processEvents, inputEvents, onError: () => undefined },
  );

  processEvents.emit("SIGINT");
  processEvents.emit("SIGTERM");
  inputEvents.emit("end");
  inputEvents.emit("close");
  await wait(0);
  assert.equal(releases, 1);
  releaseNow();
  await running;
  assert.equal(releases, 1);
  assert.equal(processEvents.listenerCount("SIGINT"), 0);
  assert.equal(inputEvents.listenerCount("close"), 0);
});

test("normal and fatal CLI returns await the same release before settling", async () => {
  for (const outcome of ["return", "fatal"] as const) {
    let releases = 0;
    let releaseNow: () => void = () => undefined;
    const releaseGate = new Promise<void>((resolve) => {
      releaseNow = resolve;
    });
    const heartbeat = startListeningHeartbeat(
      {
        acquire: async () => leaseResponse,
        renew: async () => leaseResponse,
        release: async () => {
          releases += 1;
          await releaseGate;
        },
      },
      { intervalMs: 60_000, releaseAttemptTimeoutMs: 1_000 },
    );
    await wait(0);
    let settled = false;
    const running = runCliListenerLifecycle(
      heartbeat,
      async () => {
        if (outcome === "fatal") throw new Error("synthetic CLI failure");
        return "complete";
      },
      {
        processEvents: new EventEmitter(),
        inputEvents: new EventEmitter(),
        onError: () => undefined,
      },
    );
    void running.then(
      () => {
        settled = true;
      },
      () => {
        settled = true;
      },
    );
    await wait(0);
    assert.equal(releases, 1);
    assert.equal(settled, false);
    releaseNow();
    if (outcome === "fatal") {
      await assert.rejects(running, /synthetic CLI failure/);
    } else {
      assert.equal(await running, "complete");
    }
    assert.equal(releases, 1);
  }
});

test("release attempts are bounded and local authority clears after the retry cap", async () => {
  let releases = 0;
  const originalConsoleError = console.error;
  console.error = () => undefined;
  try {
    const heartbeat = startListeningHeartbeat(
      {
        acquire: async () => leaseResponse,
        renew: async () => leaseResponse,
        release: async () => {
          releases += 1;
          return new Promise<never>(() => undefined);
        },
      },
      { intervalMs: 60_000, releaseAttemptTimeoutMs: 5 },
    );
    await wait(0);
    await heartbeat.stop();
    assert.equal(releases, 2);
    assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), false);
    assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  } finally {
    console.error = originalConsoleError;
  }
});

test("borrowed fences never release while explicitly adopted leases release once", async () => {
  const inheritedFence = {
    leaseId: leaseResponse.lease_id,
    generation: leaseResponse.generation,
    renewAfterMs: leaseResponse.renew_after_ms,
  };
  let borrowedReleases = 0;
  const borrowed = startListeningHeartbeat(
    {
      acquire: async () => {
        throw new Error("borrowed fence cannot acquire");
      },
      renew: async () => leaseResponse,
      release: async () => {
        borrowedReleases += 1;
      },
    },
    { inheritedFence },
  );
  await borrowed.stop();
  assert.equal(borrowedReleases, 0);

  let ownedReleases = 0;
  const owned = startListeningHeartbeat(
    {
      acquire: async () => {
        throw new Error("adopted fence cannot acquire");
      },
      renew: async () => leaseResponse,
      release: async () => {
        ownedReleases += 1;
      },
    },
    { inheritedFence, inheritedFenceOwned: true },
  );
  await Promise.all([owned.stop(), owned.stop()]);
  assert.equal(ownedReleases, 1);
});

test("shutdown controller publishes one promise before synchronous teardown", async () => {
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  const events = new EventEmitter();
  const shutdown = createListeningShutdownController(heartbeat, {
    bindings: [
      { source: events, event: "stop", reason: "test_stop" },
      { source: events, event: "stop", reason: "duplicate" },
    ],
  });
  const first = shutdown.stop("explicit");
  const second = shutdown.stop("concurrent");
  events.emit("stop");
  assert.equal(first, second);
  await first;
  assert.equal(events.listenerCount("stop"), 0);
});

test("stop joins a deferred acquire and releases its committed fence before resolving", async () => {
  let resolveAcquire: (value: unknown) => void = () => undefined;
  const acquireResult = new Promise<unknown>((resolve) => {
    resolveAcquire = resolve;
  });
  let releaseStarted: () => void = () => undefined;
  const releaseObserved = new Promise<void>((resolve) => {
    releaseStarted = resolve;
  });
  let finishRelease: () => void = () => undefined;
  const releaseGate = new Promise<void>((resolve) => {
    finishRelease = resolve;
  });
  const released: Array<{ leaseId: string; generation: number }> = [];
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => acquireResult,
      renew: async () => leaseResponse,
      release: async (lease) => {
        released.push({ leaseId: lease.leaseId, generation: lease.generation });
        releaseStarted();
        await releaseGate;
      },
    },
    { shutdownAcquireTimeoutMs: 1_000, releaseAttemptTimeoutMs: 1_000 },
  );

  const stopping = heartbeat.stop();
  let stopped = false;
  void stopping.then(() => {
    stopped = true;
  });
  await wait(0);
  assert.equal(stopped, false);
  assert.deepEqual(released, []);
  resolveAcquire(leaseResponse);
  await releaseObserved;
  assert.deepEqual(released, [
    { leaseId: leaseResponse.lease_id, generation: leaseResponse.generation },
  ]);
  assert.equal(stopped, false);
  assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), false);
  finishRelease();
  await stopping;
  assert.equal(stopped, true);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
});

test("concurrent stops share the deferred-acquire release", async () => {
  let resolveAcquire: (value: unknown) => void = () => undefined;
  const acquireResult = new Promise<unknown>((resolve) => {
    resolveAcquire = resolve;
  });
  let releases = 0;
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => acquireResult,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
      },
    },
    { shutdownAcquireTimeoutMs: 1_000 },
  );

  const first = heartbeat.stop();
  const second = heartbeat.stop();
  assert.equal(first, second);
  resolveAcquire(leaseResponse);
  await Promise.all([first, second]);
  assert.equal(releases, 1);
});

test("acquire rejection lets stop clear without release", async () => {
  let rejectAcquire: (error: Error) => void = () => undefined;
  const acquireResult = new Promise<unknown>((_resolve, reject) => {
    rejectAcquire = reject;
  });
  let releases = 0;
  const heartbeat = startListeningHeartbeat(
    {
      acquire: async () => acquireResult,
      renew: async () => leaseResponse,
      release: async () => {
        releases += 1;
      },
    },
    { shutdownAcquireTimeoutMs: 1_000 },
  );

  const stopping = heartbeat.stop();
  rejectAcquire(new Error("409 lease_fenced"));
  await stopping;
  assert.equal(releases, 0);
  assert.equal(hasActiveLeaseV2Authority(heartbeat.status()), false);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
});

test("stale acquire completion releases its own fence without clearing a successor", async () => {
  let resolveAcquire: (value: unknown) => void = () => undefined;
  const acquireResult = new Promise<unknown>((resolve) => {
    resolveAcquire = resolve;
  });
  let predecessorReleases = 0;
  const predecessor = startListeningHeartbeat(
    {
      acquire: async () => acquireResult,
      renew: async () => leaseResponse,
      release: async () => {
        predecessorReleases += 1;
        throw new Error('409 release: {"code":"lease_fenced"}');
      },
    },
    { shutdownAcquireTimeoutMs: 1_000 },
  );
  const predecessorStop = predecessor.stop();

  const successorLease = {
    lease_id: "lease_successor_123456789",
    generation: leaseResponse.generation + 1,
    renew_after_ms: leaseResponse.renew_after_ms,
  };
  const successor = startListeningHeartbeat(
    {
      acquire: async () => successorLease,
      renew: async () => successorLease,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  assert.equal(hasActiveLeaseV2Authority(successor.status()), true);

  resolveAcquire(leaseResponse);
  await predecessorStop;
  assert.equal(predecessorReleases, 1);
  assert.equal(hasActiveLeaseV2Authority(successor.status()), true);
  assert.equal(
    listenerHeaders()["X-Knock-Listener-Lease-ID"],
    successorLease.lease_id,
  );
  await successor.stop();
});

test("timed-out acquire completion is epoch-fenced from a successor", async () => {
  let resolveAcquire: (value: unknown) => void = () => undefined;
  const acquireResult = new Promise<unknown>((resolve) => {
    resolveAcquire = resolve;
  });
  let predecessorReleases = 0;
  const predecessor = startListeningHeartbeat(
    {
      acquire: async () => acquireResult,
      renew: async () => leaseResponse,
      release: async () => {
        predecessorReleases += 1;
      },
    },
    { shutdownAcquireTimeoutMs: 5 },
  );
  await predecessor.stop();

  const successorLease = {
    lease_id: "lease_successor_after_timeout_123",
    generation: leaseResponse.generation + 2,
    renew_after_ms: leaseResponse.renew_after_ms,
  };
  const successor = startListeningHeartbeat(
    {
      acquire: async () => successorLease,
      renew: async () => successorLease,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  resolveAcquire(leaseResponse);
  await wait(0);

  assert.equal(predecessorReleases, 0);
  assert.equal(hasActiveLeaseV2Authority(successor.status()), true);
  assert.equal(
    listenerHeaders()["X-Knock-Listener-Lease-ID"],
    successorLease.lease_id,
  );
  await successor.stop();
});
