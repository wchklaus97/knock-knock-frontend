import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  beginPhoneAskAnswerRequest,
  beginPhoneAskProgressRequest,
  completePhoneAskProgressRequest,
  getAskClaimStatus,
  markPhoneAskClaimFailure,
  resetAskClaimState,
  settlePhoneAskClaim,
  trackAgentAskResponse,
} from "./ask-claims.js";
import {
  claimAgentAsks,
  createAskClaimQueue,
} from "./ask-transport.js";
import {
  KNOCK_KNOCK_PRODUCTION_API_ORIGIN,
  KNOCK_KNOCK_STAGING_API_ORIGIN,
  apiEnvironmentId,
  sameApiEnvironment,
  selectBoundAgentCredentials,
} from "./cli-support.js";
import {
  CODEX_WAKE_PROMPT,
  buildCodexWakeSupervisorInvocation,
  buildCodexWakeEnvironment,
  createCodexWakeRunner as createCodexWakeRunnerBase,
  type PendingWakeAsk,
  type SpawnWakeProcess,
} from "./codex-wake-runner.js";
import {
  listenerAuthorityIsRevoked,
  listeningHeartbeatPath,
  listeningRegistrationPath,
  onListenerAuthorityRevoked,
  requireActiveLeaseV2Authority,
  revokeListenerAuthorityForApiResponse,
  startListeningHeartbeat,
} from "./listening.js";
import {
  listenerHeaders,
  listenerTakeoverRequested,
  setListenerLeaseFence,
} from "./thread-binding.js";
import {
  WAKE_BROKER_CAPABILITY_ENV,
  WAKE_BROKER_CAPABILITY_HEADER,
  WAKE_BROKER_URL_ENV,
  wakeCapabilityClientConfig,
  wakeCapabilityLocalFence,
} from "./wake-capability.js";
import {
  WAKE_BROKER_FORCE_DRAIN_MS,
  createWakeCapabilityBroker,
  isLoopbackWakePeer,
  type WakeCapabilityHandle,
} from "./wake-capability-broker.js";
import { spawnMacOSCredentialSandboxedProcess } from "./macos-wake-sandbox.js";
import { safeErrorMessage, sanitizeSensitiveData } from "./redaction.js";

const THREAD_ID = "123e4567-e89b-12d3-a456-426614174000";
const TEST_WAKE_CAPABILITY = "B".repeat(43);
const leaseResponse = {
  lease_id: "lease_final_blockers_123",
  generation: 7,
  renew_after_ms: 30_000,
};

function testWakeCapability() {
  let isClosed = false;
  return {
    brokerUrl: "http://127.0.0.1:43124",
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

function processIdentityExists(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

function claimAsk(claimToken: string) {
  return {
    ask_id: "ask_owner_0001",
    session_id: "ses_owner_0001",
    client_turn_id: "turn_owner_0001",
    status: "claimed",
    claim_token: claimToken,
    claim_generation: 7,
    generation: 7,
    listener_generation: 7,
    claim_deadline: new Date(Date.now() + 60_000).toISOString(),
    answerable: true,
    answered_at: null,
    legacy_drain: false,
  };
}

function wakeAsk(
  askId: string,
  revision: string,
  clientTurnId = `turn_${askId}`,
): PendingWakeAsk {
  return {
    askId,
    sessionId: `ses_${askId}`,
    revision,
    clientTurnId,
    wakeable: true,
  };
}

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

test("claim refresh is deferred behind the exact answer reservation owner", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: leaseResponse.generation,
    renewAfterMs: leaseResponse.renew_after_ms,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_owner_original")] });
  const first = beginPhoneAskAnswerRequest(
    "ses_owner_0001",
    { status: "succeeded" },
    "ask_owner_0001",
  );

  trackAgentAskResponse({ asks: [claimAsk("claim_owner_refreshed")] });
  assert.equal(getAskClaimStatus("ask_owner_0001")?.answerInFlight, true);
  assert.equal(
    markPhoneAskClaimFailure(
      "ses_owner_0001",
      "ask_owner_0001",
      new Error("competing callback"),
      "not-the-owner",
    ),
    false,
  );
  assert.equal(getAskClaimStatus("ask_owner_0001")?.answerInFlight, true);
  assert.equal(
    markPhoneAskClaimFailure(
      "ses_owner_0001",
      "ask_owner_0001",
      new Error("temporary network failure"),
      first.reservationToken,
    ),
    true,
  );

  const second = beginPhoneAskAnswerRequest(
    "ses_owner_0001",
    { status: "succeeded" },
    "ask_owner_0001",
  );
  assert.equal(second.body.claim_token, "claim_owner_refreshed");
  assert.equal(
    settlePhoneAskClaim(
      "ses_owner_0001",
      "ask_owner_0001",
      first.reservationToken,
    ),
    false,
  );
  assert.equal(getAskClaimStatus("ask_owner_0001")?.answerInFlight, true);
  assert.equal(
    settlePhoneAskClaim(
      "ses_owner_0001",
      "ask_owner_0001",
      second.reservationToken,
    ),
    true,
  );
  assert.equal(getAskClaimStatus("ask_owner_0001")?.phase, "settled");
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("progress uses listener_generation and exact owner callbacks cannot clear newer claims", () => {
  resetAskClaimState();
  setListenerLeaseFence({
    leaseId: leaseResponse.lease_id,
    generation: leaseResponse.generation,
    renewAfterMs: leaseResponse.renew_after_ms,
  });
  trackAgentAskResponse({ asks: [claimAsk("claim_progress_original")] });

  const first = beginPhoneAskProgressRequest(
    "ses_owner_0001",
    { status: "running", message: "working" },
    "ask_owner_0001",
  );
  assert.deepEqual(first.body, {
    status: "running",
    message: "working",
    ask_id: "ask_owner_0001",
    claim_token: "claim_progress_original",
    listener_generation: 7,
  });
  assert.equal(Object.hasOwn(first.body, "generation"), false);
  assert.equal(getAskClaimStatus("ask_owner_0001")?.progressInFlight, true);

  trackAgentAskResponse({ asks: [claimAsk("claim_progress_refreshed")] });
  assert.equal(
    completePhoneAskProgressRequest(
      "ses_owner_0001",
      "ask_owner_0001",
      first.reservationToken,
    ),
    true,
  );
  const second = beginPhoneAskProgressRequest(
    "ses_owner_0001",
    { status: "running" },
    "ask_owner_0001",
  );
  assert.equal(second.body.claim_token, "claim_progress_refreshed");
  assert.equal(
    markPhoneAskClaimFailure(
      "ses_owner_0001",
      "ask_owner_0001",
      new Error("stale completion"),
      first.reservationToken,
    ),
    false,
  );
  assert.equal(getAskClaimStatus("ask_owner_0001")?.progressInFlight, true);
  assert.equal(
    completePhoneAskProgressRequest(
      "ses_owner_0001",
      "ask_owner_0001",
      second.reservationToken,
    ),
    true,
  );

  const answer = beginPhoneAskAnswerRequest(
    "ses_owner_0001",
    { status: "info", idempotency_key: "event-progress-parity" },
    "ask_owner_0001",
  );
  assert.deepEqual(answer.body, {
    status: "info",
    idempotency_key: "event-progress-parity",
    ask_id: "ask_owner_0001",
    claim_token: "claim_progress_refreshed",
    generation: 7,
  });
  assert.equal(Object.hasOwn(answer.body, "listener_generation"), false);

  const rejectUnknown = (
    body: Record<string, unknown>,
    allowed: ReadonlySet<string>,
  ) => {
    const unknown = Object.keys(body).filter((field) => !allowed.has(field));
    if (unknown.length > 0) throw new Error(`unknown fields: ${unknown.join(",")}`);
  };
  assert.doesNotThrow(() =>
    rejectUnknown(
      first.body,
      new Set([
        "status",
        "message",
        "ask_id",
        "claim_token",
        "listener_generation",
      ]),
    ),
  );
  assert.throws(
    () =>
      rejectUnknown(
        { ...first.body, generation: 7 },
        new Set([
          "status",
          "message",
          "ask_id",
          "claim_token",
          "listener_generation",
        ]),
      ),
    /unknown fields: generation/,
  );
  assert.doesNotThrow(() =>
    rejectUnknown(
      answer.body,
      new Set([
        "status",
        "idempotency_key",
        "ask_id",
        "claim_token",
        "generation",
      ]),
    ),
  );
  settlePhoneAskClaim(
    "ses_owner_0001",
    "ask_owner_0001",
    answer.reservationToken,
  );
  resetAskClaimState();
  setListenerLeaseFence(null);
});

test("concurrent claim tracking is serialized in request order", async () => {
  const enqueue = createAskClaimQueue();
  const events: string[] = [];
  let releaseFirst: (() => void) | undefined;
  const firstGate = new Promise<void>((resolve) => {
    releaseFirst = resolve;
  });
  const first = enqueue(async () => {
    events.push("first:start");
    await firstGate;
    events.push("first:end");
    return 1;
  });
  const second = enqueue(async () => {
    events.push("second:start", "second:end");
    return 2;
  });
  await wait(0);
  assert.deepEqual(events, ["first:start"]);
  releaseFirst?.();
  assert.deepEqual(await Promise.all([first, second]), [1, 2]);
  assert.deepEqual(events, [
    "first:start",
    "first:end",
    "second:start",
    "second:end",
  ]);
});

test("client_turn_id changes never mint a fresh wake budget for one ask_id", async () => {
  let clock = 10_000;
  let observations = [wakeAsk("ask_canonical", "revision-1")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 1,
    now: () => clock,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  await runner.pollNow();
  children[0].emit("exit", 75, null);
  await wait(0);
  clock += 60_000;
  observations = [wakeAsk("ask_canonical", "revision-2", "changed-turn")];
  await runner.pollNow();
  assert.equal(children.length, 1);
  runner.stop();
});

test("successful-but-unsettled wake remains observable at cumulative cap one", async () => {
  let clock = 40_000;
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    pollPending: async () => [wakeAsk("ask_cap_one", "queued-v1")],
    maxWakeAttemptsPerAsk: 1,
    now: () => clock,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });

  await runner.pollNow();
  children[0].emit("exit", 0, null);
  await wait(2);
  clock += 120_000;
  await runner.pollNow();
  assert.equal(children.length, 1);
  assert.deepEqual(runner.snapshot(), { state: "exhausted", askCount: 1 });
  runner.stop();
});

test("child exit zero re-observes an unchanged unsettled Ask and retries after cooldown", async () => {
  let clock = 20_000;
  let observations = [wakeAsk("ask_unsettled", "queued-v1")];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    pollPending: async () => observations,
    maxWakeAttemptsPerAsk: 2,
    now: () => clock,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });

  await runner.pollNow();
  children[0].emit("exit", 0, null);
  await wait(2);
  await runner.pollNow();
  assert.equal(children.length, 1, "unchanged state cannot immediately re-wake");

  clock += 2_001;
  await runner.pollNow();
  assert.equal(children.length, 2, "successful exit does not exhaust retry budget");

  observations = [];
  children[1].emit("exit", 0, null);
  await wait(2);
  clock += 60_000;
  observations = [wakeAsk("ask_unsettled", "late-reappearance")];
  await runner.pollNow();
  assert.equal(children.length, 2, "authoritative removal settles the wake identity");
  runner.stop();
});

test(
  "stable supervisor KILL escalation survives leader exit after TERM",
  { skip: process.platform === "win32" },
  async (t) => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-final-supervisor-"));
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
    let supervisor: ReturnType<typeof spawn> | undefined;
    let supervisorClose:
      | Promise<{ code: number | null; signal: NodeJS.Signals | null }>
      | undefined;
    let legacyPgidOwner = "owned-supervisor";
    const legacyGroupSignals: Array<{
      owner: string;
      groupId: number;
      signal: NodeJS.Signals;
    }> = [];
    const runner = createCodexWakeRunner({
      chatId: THREAD_ID,
      pollPending: async () => [wakeAsk("ask_descendant", "queued-v1")],
      childKillGraceMs: 250,
      platform: "darwin",
      spawnProcess: ((_command, _args, options) => {
        const invocation = buildCodexWakeSupervisorInvocation(
          process.execPath,
          ["-e", leaderSource, descendantSource, markerPath, pidPath],
          50,
        );
        const child = spawn(invocation.command, [...invocation.args], {
          env: options.env,
          detached: options.detached,
          stdio: "ignore",
        });
        supervisor = child;
        supervisorClose = new Promise((resolve) => {
          child.once("close", (code, signal) => resolve({ code, signal }));
        });
        return child;
      }) as SpawnWakeProcess,
      signalProcessGroup: (groupId: number, signal: NodeJS.Signals) => {
        legacyGroupSignals.push({ owner: legacyPgidOwner, groupId, signal });
        return true;
      },
      logger: () => undefined,
    } as Parameters<typeof createCodexWakeRunner>[0] & {
      signalProcessGroup: (groupId: number, signal: NodeJS.Signals) => boolean;
    });
    t.after(async () => {
      runner.stop();
      if (
        supervisor &&
        supervisor.exitCode === null &&
        supervisor.signalCode === null
      ) {
        const closed = new Promise<void>((resolve) => {
          supervisor?.once("close", () => resolve());
        });
        supervisor.kill("SIGKILL");
        await Promise.race([closed, wait(1_000)]);
      }
      fs.rmSync(directory, { recursive: true, force: true });
    });

    await runner.pollNow();
    assert.ok(supervisorClose);
    const result = await Promise.race([
      supervisorClose,
      wait(2_000).then(() => {
        throw new Error("stable wake supervisor did not close");
      }),
    ]);
    assert.deepEqual(result, { code: 0, signal: null });
    assert.equal(fs.readFileSync(markerPath, "utf8"), "ready\nterm\n");
    const descendantPid = Number(fs.readFileSync(pidPath, "utf8"));
    assert.equal(processIdentityExists(descendantPid), false);
    assert.deepEqual(legacyGroupSignals, []);

    runner.stop();
    legacyPgidOwner = "unrelated-reused-pgid";
    await wait(275);
    assert.deepEqual(legacyGroupSignals, []);
  },
);

test("resumed child uses only an Ask-scoped broker while the parent owns and renews the fence", async (t) => {
  resetAskClaimState();
  const askId = "ask_broker_0001";
  const sessionId = "ses_broker_0001";
  const realClaimToken = "claim_parent_only_secret";
  let parentRenewals = 0;
  const backendRoutes: string[] = [];
  const parent = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => {
        parentRenewals += 1;
        return leaseResponse;
      },
    },
    { intervalMs: 5 },
  );
  await wait(1);
  let broker: WakeCapabilityHandle | undefined;
  const child = new FakeWakeChild(6161);
  const spawnCalls: Array<{
    command: string;
    args: readonly string[];
    env: NodeJS.ProcessEnv;
  }> = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    pollPending: async () => [
      { ...wakeAsk(askId, "queued-v1"), sessionId },
    ],
    openWakeCapability: async (ask) => {
      assert.equal(ask.askId, askId);
      assert.equal(ask.sessionId, sessionId);
      broker = await createWakeCapabilityBroker({
        askId,
        sessionId,
        requireAuthority: () => requireActiveLeaseV2Authority(parent.status()),
        backendRequest: async (requestPath, init) => {
          backendRoutes.push(requestPath);
          assert.equal(
            listenerHeaders()["X-Knock-Listener-Lease-ID"],
            leaseResponse.lease_id,
          );
          assert.equal(listenerHeaders()["X-Knock-Listener-Generation"], "7");
          if (requestPath === "/v1/agents/me/asks/claim") {
            assert.equal(init.method, "POST");
            assert.equal(init.body, undefined);
            assert.equal(init.json, undefined);
            return {
              asks: [
                {
                  ask_id: askId,
                  session_id: sessionId,
                  client_turn_id: `turn_${askId}`,
                  status: "claimed",
                  transcript: "authorized transcript",
                  claim_token: realClaimToken,
                  claim_generation: 7,
                  generation: 7,
                  listener_generation: 7,
                  claim_deadline: new Date(Date.now() + 60_000).toISOString(),
                  answerable: true,
                  answered_at: null,
                  legacy_drain: false,
                },
              ],
            };
          }
          const body = init.json as Record<string, unknown>;
          if (requestPath.endsWith("/progress")) {
            assert.equal(body.ask_id, askId);
            assert.equal(body.claim_token, realClaimToken);
            assert.equal(body.listener_generation, 7);
          } else if (requestPath.endsWith("/events")) {
            assert.equal(body.ask_id, askId);
            assert.equal(body.claim_token, realClaimToken);
            assert.equal(body.generation, 7);
          } else {
            throw new Error(`unexpected backend route: ${requestPath}`);
          }
          return {
            ok: true,
            transcript: "must not leave broker",
            claim_token: realClaimToken,
          };
        },
      });
      return broker;
    },
    parentEnv: {
      PATH: "/usr/bin",
      CODEX_HOME: "/Users/test/.codex",
      KNOCK_KNOCK_AGENT_ENV: "/tmp/private-agent.env",
      KNOCK_KNOCK_AGENT_KEY: "vak_parent_secret",
      BRIDGE_AGENT_KEY: "vak_bridge_secret",
      KNOCK_KNOCK_LISTENER_LEASE_ID: leaseResponse.lease_id,
      KNOCK_KNOCK_LISTENER_GENERATION: "7",
      KNOCK_KNOCK_API_URL: KNOCK_KNOCK_STAGING_API_ORIGIN,
    },
    platform: "win32",
    spawnProcess: ((command, args, options) => {
      spawnCalls.push({ command, args, env: options.env });
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(async () => {
    runner.stop();
    if (broker) await broker.close();
    parent.stop();
  });

  await runner.pollNow();
  assert.ok(broker);
  const activeBroker = broker;
  assert.equal(spawnCalls.length, 1);
  assert.deepEqual(spawnCalls[0].args, [
    "exec",
    "resume",
    "--all",
    THREAD_ID,
    CODEX_WAKE_PROMPT,
  ]);
  const childMaterial = JSON.stringify(spawnCalls[0]);
  assert.doesNotMatch(
    childMaterial,
    /private-agent\.env|vak_parent_secret|vak_bridge_secret|lease_final_blockers_123|LISTENER_GENERATION|KNOCK_KNOCK_API_URL/,
  );
  assert.deepEqual(Object.keys(spawnCalls[0].env).sort(), [
    "CODEX_HOME",
    "CODEX_THREAD_ID",
    "KNOCK_KNOCK_WAKE_BROKER_URL",
    "KNOCK_KNOCK_WAKE_CAPABILITY",
    "PATH",
  ]);

  const brokerRequest = (
    requestPath: string,
    method: string,
    body?: Record<string, unknown>,
    capability = activeBroker.capability,
  ) =>
    fetch(`${activeBroker.brokerUrl}${requestPath}`, {
      method,
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: capability,
        ...(body ? { "content-type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

  assert.equal((await brokerRequest(listeningRegistrationPath(), "POST")).status, 403);
  assert.equal((await brokerRequest(listeningHeartbeatPath(), "POST")).status, 403);
  assert.equal((await brokerRequest("/v1/agents/me/asks", "GET")).status, 403);
  assert.equal(
    (await brokerRequest("/v1/agents/me/asks/claim", "POST", undefined, `${activeBroker.capability}x`)).status,
    401,
  );

  const claimResponse = await brokerRequest("/v1/agents/me/asks/claim", "POST");
  assert.equal(claimResponse.status, 200);
  const claimPayload = (await claimResponse.json()) as {
    asks: Array<Record<string, unknown>>;
  };
  const localClaimToken = claimPayload.asks[0].claim_token as string;
  assert.equal(claimPayload.asks[0].ask_id, askId);
  assert.equal(claimPayload.asks[0].session_id, sessionId);
  assert.equal(claimPayload.asks[0].transcript, "authorized transcript");
  assert.notEqual(localClaimToken, realClaimToken);
  assert.equal((await brokerRequest("/v1/agents/me/asks/claim", "POST")).status, 409);

  assert.equal(
    (
      await brokerRequest(`/v1/sessions/${sessionId}/progress`, "POST", {
        status: "working",
        ask_id: "ask_other",
        claim_token: localClaimToken,
        listener_generation: 1,
      })
    ).status,
    403,
  );
  const progressResponse = await brokerRequest(
    `/v1/sessions/${sessionId}/progress`,
    "POST",
    {
      status: "working",
      message: "processing",
      ask_id: askId,
      claim_token: localClaimToken,
      listener_generation: 1,
    },
  );
  assert.equal(progressResponse.status, 200);
  assert.doesNotMatch(await progressResponse.text(), /must not leave broker|claim_parent_only_secret/);

  const terminal = new Promise<void>((resolve) => {
    activeBroker.onTerminal(resolve);
  });
  const eventResponse = await brokerRequest(
    `/v1/sessions/${sessionId}/events`,
    "POST",
    {
      status: "succeeded",
      summary: "completed",
      ask_id: askId,
      claim_token: localClaimToken,
      generation: 1,
    },
  );
  assert.equal(eventResponse.status, 200);
  assert.doesNotMatch(await eventResponse.text(), /must not leave broker|claim_parent_only_secret/);
  await terminal;
  assert.equal(activeBroker.closed(), true);
  assert.deepEqual(child.signals, []);
  assert.deepEqual(backendRoutes, [
    "/v1/agents/me/asks/claim",
    `/v1/sessions/${sessionId}/progress`,
    `/v1/sessions/${sessionId}/events`,
  ]);
  assert.ok(parentRenewals >= 1);
  child.emit("close", 0, null);
  runner.stop();
  parent.stop();
});

test("broker serializes simultaneous claims and permits exactly one transient retry", async (t) => {
  const authority = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  t.after(() => authority.stop());
  await wait(0);
  const askId = "ask_claim_state_0001";
  const sessionId = "ses_claim_state_0001";
  const claimedAsk = {
    ask_id: askId,
    session_id: sessionId,
    status: "claimed",
    claim_token: "claim_real_state_secret",
    claim_generation: 7,
    generation: 7,
    listener_generation: 7,
    claim_deadline: new Date(Date.now() + 60_000).toISOString(),
    answerable: true,
    legacy_drain: false,
  };
  let releaseFirst!: () => void;
  let markFirstStarted!: () => void;
  const firstGate = new Promise<void>((resolve) => {
    releaseFirst = resolve;
  });
  const firstStarted = new Promise<void>((resolve) => {
    markFirstStarted = resolve;
  });
  let concurrentBackendCalls = 0;
  const concurrentBroker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async () => {
      concurrentBackendCalls += 1;
      markFirstStarted();
      await firstGate;
      return { asks: [claimedAsk] };
    },
  });
  t.after(async () => {
    releaseFirst();
    await concurrentBroker.close();
  });
  const claim = (broker: WakeCapabilityHandle) =>
    fetch(`${broker.brokerUrl}/v1/agents/me/asks/claim`, {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability,
      },
    });

  const firstClaim = claim(concurrentBroker);
  await firstStarted;
  const concurrentClaim = await claim(concurrentBroker);
  assert.equal(concurrentClaim.status, 409);
  assert.equal(concurrentBackendCalls, 1);
  releaseFirst();
  assert.equal((await firstClaim).status, 200);
  assert.equal(concurrentBackendCalls, 1);

  let retryBackendCalls = 0;
  const retryBroker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async () => {
      retryBackendCalls += 1;
      if (retryBackendCalls === 1) throw new Error("503 temporary_backend_failure");
      return { asks: [claimedAsk] };
    },
  });
  t.after(() => retryBroker.close());
  assert.equal((await claim(retryBroker)).status, 502);
  assert.equal(retryBroker.closed(), false);
  assert.equal((await claim(retryBroker)).status, 200);
  assert.equal((await claim(retryBroker)).status, 409);
  assert.equal(retryBackendCalls, 2);
  await retryBroker.close();
  assert.equal(retryBroker.closed(), true);
});

test("claim retry is transient-only and settles after its single retry", async (t) => {
  const claim = (broker: WakeCapabilityHandle) =>
    fetch(`${broker.brokerUrl}/v1/agents/me/asks/claim`, {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability,
      },
    });

  let transientBackendCalls = 0;
  const transientBroker = await createWakeCapabilityBroker({
    askId: "ask_claim_transient_0001",
    sessionId: "ses_claim_transient_0001",
    requireAuthority: () => undefined,
    backendRequest: async () => {
      transientBackendCalls += 1;
      throw new Error("503 temporary_claim_failure");
    },
  });
  t.after(() => transientBroker.close());
  const initialTransient = await claim(transientBroker);
  assert.equal(initialTransient.status, 502);
  assert.deepEqual(await initialTransient.json(), {
    code: "wake_backend_failed",
  });
  assert.equal(transientBackendCalls, 1);

  const retryTransient = await claim(transientBroker);
  assert.equal(retryTransient.status, 502);
  assert.deepEqual(await retryTransient.json(), {
    code: "wake_backend_failed",
  });
  assert.equal(transientBackendCalls, 2);

  assert.equal((await claim(transientBroker)).status, 409);
  assert.equal(transientBackendCalls, 2);
  assert.equal((await claim(transientBroker)).status, 409);
  assert.equal(transientBackendCalls, 2);
  assert.equal(transientBroker.closed(), false);

  let permanentBackendCalls = 0;
  const permanentBroker = await createWakeCapabilityBroker({
    askId: "ask_claim_permanent_0001",
    sessionId: "ses_claim_permanent_0001",
    requireAuthority: () => undefined,
    backendRequest: async () => {
      permanentBackendCalls += 1;
      throw new Error("400 permanent_claim_error");
    },
  });
  t.after(() => permanentBroker.close());
  const permanentFailure = await claim(permanentBroker);
  assert.equal(permanentFailure.status, 502);
  assert.deepEqual(await permanentFailure.json(), {
    code: "wake_backend_failed",
  });
  assert.equal(permanentBackendCalls, 1);

  assert.equal((await claim(permanentBroker)).status, 409);
  assert.equal(permanentBackendCalls, 1);
  assert.equal((await claim(permanentBroker)).status, 409);
  assert.equal(permanentBackendCalls, 1);
  assert.equal(permanentBroker.closed(), false);
});

test("terminal event authority rejects a different concurrent payload before backend await", async (t) => {
  const askId = "ask_terminal_atomic_0001";
  const sessionId = "ses_terminal_atomic_0001";
  let eventBackendCalls = 0;
  let releaseFirst!: () => void;
  let markFirstStarted!: () => void;
  const firstGate = new Promise<void>((resolve) => {
    releaseFirst = resolve;
  });
  const firstStarted = new Promise<void>((resolve) => {
    markFirstStarted = resolve;
  });
  const broker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async (requestPath) => {
      if (requestPath === "/v1/agents/me/asks/claim") {
        return {
          asks: [
            {
              ask_id: askId,
              session_id: sessionId,
              claim_token: "claim_terminal_atomic_secret",
              claim_generation: 7,
              listener_generation: 7,
              answerable: true,
            },
          ],
        };
      }
      eventBackendCalls += 1;
      markFirstStarted();
      await firstGate;
      return { ok: true };
    },
  });
  t.after(async () => {
    releaseFirst();
    await broker.close();
  });
  const headers = { [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability };
  const claimResponse = await fetch(
    `${broker.brokerUrl}/v1/agents/me/asks/claim`,
    { method: "POST", headers },
  );
  const claimed = (await claimResponse.json()) as {
    asks: Array<{ claim_token: string }>;
  };
  const terminalRequest = (summary: string, idempotencyKey: string) =>
    fetch(`${broker.brokerUrl}/v1/sessions/${sessionId}/events`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({
        status: "succeeded",
        summary,
        idempotency_key: idempotencyKey,
        ask_id: askId,
        claim_token: claimed.asks[0].claim_token,
        generation: 1,
      }),
    });

  const first = terminalRequest("first terminal result", "terminal_atomic_first");
  await firstStarted;
  const conflicting = await terminalRequest(
    "conflicting terminal result",
    "terminal_atomic_second",
  );
  assert.equal(conflicting.status, 409);
  assert.equal(eventBackendCalls, 1);
  releaseFirst();
  assert.equal((await first).status, 200);
  assert.equal(eventBackendCalls, 1);
});

test("terminal transient retry requires the exact idempotency key and request identity", async (t) => {
  const askId = "ask_terminal_retry_0001";
  const sessionId = "ses_terminal_retry_0001";
  let eventBackendCalls = 0;
  const eventPayloads: string[] = [];
  const broker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async (requestPath, requestOptions) => {
      if (requestPath === "/v1/agents/me/asks/claim") {
        return {
          asks: [
            {
              ask_id: askId,
              session_id: sessionId,
              claim_token: "claim_terminal_retry_secret",
              claim_generation: 7,
              listener_generation: 7,
              answerable: true,
            },
          ],
        };
      }
      eventBackendCalls += 1;
      eventPayloads.push(JSON.stringify(requestOptions?.json) ?? "");
      if (eventBackendCalls === 1) throw new Error("503 temporary_backend_failure");
      return { ok: true };
    },
  });
  t.after(() => broker.close());
  const headers = { [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability };
  const claimResponse = await fetch(
    `${broker.brokerUrl}/v1/agents/me/asks/claim`,
    { method: "POST", headers },
  );
  const claimed = (await claimResponse.json()) as {
    asks: Array<{ claim_token: string }>;
  };
  const body = {
    status: "info",
    summary: "exact retry result",
    idempotency_key: "terminal_retry_exact",
    ask_id: askId,
    claim_token: claimed.asks[0].claim_token,
    generation: 1,
  };
  const report = (value: Record<string, unknown>) =>
    fetch(`${broker.brokerUrl}/v1/sessions/${sessionId}/events`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify(value),
    });

  assert.equal((await report(body)).status, 502);
  assert.equal(broker.closed(), false);
  assert.equal(
    (await report({ ...body, summary: "changed retry result" })).status,
    409,
  );
  assert.equal(
    (await report({ ...body, idempotency_key: "terminal_retry_changed" })).status,
    409,
  );
  assert.equal(eventBackendCalls, 1);
  assert.equal(
    (
      await report({
        generation: body.generation,
        claim_token: body.claim_token,
        ask_id: body.ask_id,
        idempotency_key: body.idempotency_key,
        summary: body.summary,
        status: body.status,
      })
    ).status,
    200,
  );
  assert.equal(eventBackendCalls, 2);
  assert.equal(eventPayloads.length, 2);
  assert.equal(eventPayloads[1], eventPayloads[0]);
  assert.equal(broker.closed(), true);
});

test("terminal exhaustion drains before settling the runner and cannot rearm", async (t) => {
  const askId = "ask_terminal_exhausted_0001";
  const sessionId = "ses_terminal_exhausted_0001";
  const observations: PendingWakeAsk[] = [
    { ...wakeAsk(askId, "queued-v1"), sessionId },
  ];
  let broker: WakeCapabilityHandle | undefined;
  let heldSocket: net.Socket | undefined;
  let capabilityOpenCalls = 0;
  let claimBackendCalls = 0;
  let eventBackendCalls = 0;
  let progressBackendCalls = 0;
  let resolveTerminated!: () => void;
  const terminated = new Promise<void>((resolve) => {
    resolveTerminated = resolve;
  });
  class SettlementAwareChild extends FakeWakeChild {
    kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
      const result = super.kill(signal);
      if (signal === "SIGTERM") {
        resolveTerminated();
        queueMicrotask(() => this.emit("close", 0, null));
      }
      return result;
    }
  }
  const children: SettlementAwareChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    platform: "win32",
    pollPending: async () => observations,
    openWakeCapability: async () => {
      capabilityOpenCalls += 1;
      broker = await createWakeCapabilityBroker({
        askId,
        sessionId,
        requireAuthority: () => undefined,
        backendRequest: async (requestPath) => {
          if (requestPath === "/v1/agents/me/asks/claim") {
            claimBackendCalls += 1;
            return {
              asks: [
                {
                  ask_id: askId,
                  session_id: sessionId,
                  claim_token: "claim_terminal_exhausted_secret",
                  claim_generation: 7,
                  listener_generation: 7,
                  answerable: true,
                },
              ],
            };
          }
          if (requestPath === `/v1/sessions/${sessionId}/progress`) {
            progressBackendCalls += 1;
            return { ok: true };
          }
          eventBackendCalls += 1;
          throw new Error("503 repeated_terminal_failure");
        },
      });
      return broker;
    },
    spawnProcess: (() => {
      const child = new SettlementAwareChild();
      children.push(child);
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(async () => {
    heldSocket?.destroy();
    runner.stop();
    if (broker) await broker.close();
  });

  await runner.pollNow();
  assert.ok(broker);
  const activeBroker = broker;
  const headers = {
    [WAKE_BROKER_CAPABILITY_HEADER]: activeBroker.capability,
  };
  const claimResponse = await fetch(
    `${activeBroker.brokerUrl}/v1/agents/me/asks/claim`,
    { method: "POST", headers },
  );
  const claimed = (await claimResponse.json()) as {
    asks: Array<{ claim_token: string }>;
  };
  const report = (summary: string) =>
    fetch(`${activeBroker.brokerUrl}/v1/sessions/${sessionId}/events`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({
        status: "failed",
        summary,
        idempotency_key: "terminal_exhausted_once",
        ask_id: askId,
        claim_token: claimed.asks[0].claim_token,
        generation: 1,
      }),
    });

  const terminalEvents: string[] = [];
  let drainedAtTerminal = false;
  let resolveTerminal!: () => void;
  const terminalObserved = new Promise<void>((resolve) => {
    resolveTerminal = resolve;
  });
  const unsubscribe = activeBroker.onTerminal((event) => {
    terminalEvents.push(event.reason);
    drainedAtTerminal = !activeBroker.hasActiveResponse();
    resolveTerminal();
  });
  t.after(unsubscribe);

  const initialFailure = await report("same terminal result");
  assert.equal(initialFailure.status, 502);
  assert.deepEqual(await initialFailure.json(), {
    code: "wake_backend_failed",
  });
  assert.deepEqual(terminalEvents, []);
  assert.equal(eventBackendCalls, 1);

  const endpoint = new URL(activeBroker.brokerUrl);
  heldSocket = net.createConnection({
    host: endpoint.hostname,
    port: Number(endpoint.port),
  });
  heldSocket.on("error", () => undefined);
  await new Promise<void>((resolve) => heldSocket?.once("connect", resolve));

  const exhaustedFailure = await report("same terminal result");
  assert.equal(exhaustedFailure.status, 502);
  assert.deepEqual(await exhaustedFailure.json(), {
    code: "wake_backend_failed",
  });
  assert.deepEqual(terminalEvents, []);
  assert.equal(activeBroker.closed(), false);

  const progressResponse = await fetch(
    `${activeBroker.brokerUrl}/v1/sessions/${sessionId}/progress`,
    {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({
        status: "working",
        ask_id: askId,
        claim_token: claimed.asks[0].claim_token,
        listener_generation: 1,
      }),
    },
  );
  assert.equal(progressResponse.status, 409);
  assert.equal(
    (
      await fetch(`${activeBroker.brokerUrl}/v1/agents/me/asks/claim`, {
        method: "POST",
        headers,
      })
    ).status,
    409,
  );
  assert.equal((await report("same terminal result")).status, 409);
  assert.equal((await report("different terminal result")).status, 409);
  assert.equal(claimBackendCalls, 1);
  assert.equal(eventBackendCalls, 2);
  assert.equal(progressBackendCalls, 0);

  heldSocket.destroy();
  heldSocket = undefined;
  await terminalObserved;
  await terminated;
  await wait(0);
  assert.deepEqual(terminalEvents, ["settled"]);
  assert.equal(drainedAtTerminal, true);
  assert.equal(activeBroker.closed(), true);
  assert.deepEqual(children[0].signals, ["SIGTERM"]);

  await runner.pollNow();
  assert.equal(capabilityOpenCalls, 1);
  assert.equal(children.length, 1);
  assert.equal(claimBackendCalls, 1);
  assert.equal(eventBackendCalls, 2);
  assert.equal(progressBackendCalls, 0);
});

test("permanent terminal backend failure settles terminal authority", async (t) => {
  const askId = "ask_terminal_permanent_0001";
  const sessionId = "ses_terminal_permanent_0001";
  let eventBackendCalls = 0;
  const broker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async (requestPath) => {
      if (requestPath === "/v1/agents/me/asks/claim") {
        return {
          asks: [
            {
              ask_id: askId,
              session_id: sessionId,
              claim_token: "claim_terminal_permanent_secret",
              claim_generation: 7,
              listener_generation: 7,
              answerable: true,
            },
          ],
        };
      }
      eventBackendCalls += 1;
      throw new Error("400 terminal_payload_rejected");
    },
  });
  t.after(() => broker.close());
  const headers = { [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability };
  const claimResponse = await fetch(
    `${broker.brokerUrl}/v1/agents/me/asks/claim`,
    { method: "POST", headers },
  );
  const claimed = (await claimResponse.json()) as {
    asks: Array<{ claim_token: string }>;
  };
  const terminalEvents: string[] = [];
  let drainedAtTerminal = false;
  let resolveTerminal!: () => void;
  const terminalObserved = new Promise<void>((resolve) => {
    resolveTerminal = resolve;
  });
  const unsubscribe = broker.onTerminal((event) => {
    terminalEvents.push(event.reason);
    drainedAtTerminal = !broker.hasActiveResponse();
    resolveTerminal();
  });
  t.after(unsubscribe);
  const report = (summary: string) =>
    fetch(`${broker.brokerUrl}/v1/sessions/${sessionId}/events`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({
        status: "failed",
        summary,
        idempotency_key: "terminal_permanent_once",
        ask_id: askId,
        claim_token: claimed.asks[0].claim_token,
        generation: 1,
      }),
    });
  const failure = await report("permanent failure");
  assert.equal(failure.status, 502);
  assert.deepEqual(await failure.json(), { code: "wake_backend_failed" });
  await terminalObserved;
  await wait(0);
  assert.deepEqual(terminalEvents, ["settled"]);
  assert.equal(drainedAtTerminal, true);
  assert.equal(eventBackendCalls, 1);
  assert.equal(broker.closed(), true);
});

test("a newer Ask revision re-arms its bounded wake attempts exactly once", async (t) => {
  let clock = 20_000;
  let observations: PendingWakeAsk[] = [
    {
      ...wakeAsk("ask_revision", "revision-v1"),
      authorityGeneration: 7,
    },
  ];
  const children: FakeWakeChild[] = [];
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    pollPending: async () => observations,
    now: () => clock,
    backoffBaseMs: 1,
    backoffMaxMs: 1,
    maxWakeAttemptsPerAsk: 2,
    spawnProcess: (() => {
      const child = new FakeWakeChild();
      children.push(child);
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(() => runner.stop());

  await runner.pollNow();
  children[0].emit("exit", 75, null);
  await wait(0);
  clock += 2;
  await runner.pollNow();
  children[1].emit("exit", 75, null);
  await wait(0);
  clock += 2;
  await runner.pollNow();
  assert.equal(children.length, 2);
  assert.equal(runner.snapshot().state, "exhausted");

  observations = [
    {
      ...wakeAsk("ask_revision", "client-turn-only-revision"),
      authorityGeneration: 7,
      clientTurnId: "turn_mutation_must_not_rearm",
    },
  ];
  await runner.pollNow();
  assert.equal(children.length, 2);

  observations = [
    {
      ...wakeAsk("ask_revision", "revision-v2"),
      authorityGeneration: 8,
    },
  ];
  await runner.pollNow();
  assert.equal(children.length, 3);
  children[2].emit("exit", 0, null);
  await wait(0);
  observations = [
    {
      ...wakeAsk("ask_revision", "revision-v3-terminal"),
      authorityGeneration: 8,
      terminal: true,
      wakeable: false,
    },
  ];
  await runner.pollNow();
  assert.equal(children.length, 3);
});

test("authenticated malformed and override request targets return sanitized 400 without crashing", async (t) => {
  const askId = "ask_malformed_0001";
  const sessionId = "ses_malformed_0001";
  let backendCalls = 0;
  const broker = await createWakeCapabilityBroker({
    askId,
    sessionId,
    requireAuthority: () => undefined,
    backendRequest: async () => {
      backendCalls += 1;
      return {
        asks: [
          {
            ask_id: askId,
            session_id: sessionId,
            claim_token: "claim_malformed_real_secret",
            claim_generation: 7,
            listener_generation: 7,
            answerable: true,
          },
        ],
      };
    },
  });
  t.after(() => broker.close());
  const port = Number(new URL(broker.brokerUrl).port);
  const rawRequest = (target: string, extraHeaders = "") =>
    new Promise<string>((resolve, reject) => {
      const socket = net.createConnection({ host: "127.0.0.1", port });
      let response = "";
      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        response += chunk;
      });
      socket.once("error", reject);
      socket.once("close", () => resolve(response));
      socket.once("connect", () => {
        socket.end(
          `POST ${target} HTTP/1.1\r\n` +
            `Host: 127.0.0.1:${port}\r\n` +
            `${WAKE_BROKER_CAPABILITY_HEADER}: ${broker.capability}\r\n` +
            `${extraHeaders}` +
            "Connection: close\r\n\r\n",
        );
      });
    });

  for (const target of [
    "/v1/agents/me/asks/%ZZ",
    "http://attacker.invalid/v1/agents/me/asks/claim",
    "attacker.invalid:443",
    "/v1/agents/me/asks/%63laim",
  ]) {
    const response = await rawRequest(target);
    assert.match(response, /^HTTP\/1\.1 400 /);
    assert.doesNotMatch(response, /claim_malformed_real_secret|wake_capability/i);
  }
  const overrideResponse = await rawRequest(
    "/v1/agents/me/asks/claim",
    "X-HTTP-Method-Override: GET\r\n",
  );
  assert.match(overrideResponse, /^HTTP\/1\.1 400 /);
  assert.equal(backendCalls, 0);

  const bodyOverrideResponse = await fetch(
    `${broker.brokerUrl}/v1/agents/me/asks/claim`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability,
        "content-type": "application/json",
      },
      body: "{}",
    },
  );
  assert.equal(bodyOverrideResponse.status, 400);
  assert.equal(backendCalls, 0);

  const validResponse = await fetch(
    `${broker.brokerUrl}/v1/agents/me/asks/claim`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: broker.capability,
      },
    },
  );
  assert.equal(validResponse.status, 200);
  assert.equal(backendCalls, 1);
});

test("bounded broker drain destroys an incomplete pre-header socket", async (t) => {
  const broker = await createWakeCapabilityBroker({
    askId: "ask_incomplete_socket_0001",
    sessionId: "ses_incomplete_socket_0001",
    requireAuthority: () => undefined,
    backendRequest: async () => {
      throw new Error("incomplete socket must never reach the backend");
    },
  });
  t.after(() => broker.close());
  const port = Number(new URL(broker.brokerUrl).port);
  const socket = net.createConnection({ host: "127.0.0.1", port });
  t.after(() => socket.destroy());
  await new Promise<void>((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  const socketClosed = new Promise<void>((resolve) => socket.once("close", resolve));
  socket.write("POST /v1/agents/me/asks/claim HTTP/1.1\r\nHost: 127.0.0.1");

  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const outcome = await Promise.race([
      broker.close().then(() => "closed" as const),
      new Promise<"timeout">((resolve) => {
        timeout = setTimeout(
          () => resolve("timeout"),
          WAKE_BROKER_FORCE_DRAIN_MS + 1_000,
        );
        timeout.unref();
      }),
    ]);
    assert.equal(outcome, "closed");
  } finally {
    if (timeout) clearTimeout(timeout);
  }
  await socketClosed;
  assert.equal(socket.destroyed, true);
});

test(
  "macOS Seatbelt child cannot read credentials but can read repository files",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "wake-seatbelt-"));
    const credentialPath = path.join(directory, "agent.env");
    const probePath = path.join(directory, "probe.cjs");
    const repositoryFile = fileURLToPath(new URL("../../../package.json", import.meta.url));
    fs.writeFileSync(
      credentialPath,
      "BRIDGE_API_URL=https://example.test\nBRIDGE_AGENT_KEY=vak_private\n",
      { mode: 0o600 },
    );
    fs.writeFileSync(
      probePath,
      [
        'const fs = require("node:fs");',
        "let credentialDenied = false;",
        `try { fs.readFileSync(${JSON.stringify(credentialPath)}); } catch { credentialDenied = true; }`,
        "if (!credentialDenied) process.exit(71);",
        `try { fs.readFileSync(${JSON.stringify(repositoryFile)}); } catch { process.exit(72); }`,
        "process.exit(0);",
        "",
      ].join("\n"),
      { mode: 0o600 },
    );
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

    const child = spawnMacOSCredentialSandboxedProcess(
      process.execPath,
      [probePath],
      { env: { PATH: process.env.PATH }, detached: false },
      [credentialPath],
    );
    t.after(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    });
    const result = await new Promise<{
      code: number | null;
      signal: NodeJS.Signals | null;
    }>((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("Seatbelt probe did not exit"));
      }, 5_000);
      timeout.unref();
      child.once("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once("close", (code, signal) => {
        clearTimeout(timeout);
        resolve({ code, signal });
      });
    });
    assert.deepEqual(result, { code: 0, signal: null });
  },
);

test(
  "macOS target anti-attach blocks a renamed debugserver and hides parent AgentKey",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const crypto = await import("node:crypto");
    const { fileURLToPath } = await import("node:url");
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "wake-parent-probe-"));
    const credentialPath = path.join(directory, "agent.env");
    const protectedParentPath = path.join(directory, "protected-parent.cjs");
    const probePath = path.join(directory, "probe.cjs");
    const resultPath = path.join(directory, "result.json");
    const nativeBindingPath = fileURLToPath(
      new URL("../build/Release/macos_deny_attach.node", import.meta.url),
    );
    const agentKey = `vak_${crypto.randomBytes(32).toString("hex")}`;
    const agentKeyDigest = crypto
      .createHash("sha256")
      .update(agentKey)
      .digest("hex");
    fs.writeFileSync(credentialPath, `BRIDGE_AGENT_KEY=${agentKey}\n`, {
      mode: 0o600,
    });
    fs.writeFileSync(
      protectedParentPath,
      [
        'const fs = require("node:fs");',
        `const binding = require(${JSON.stringify(nativeBindingPath)});`,
        'if (binding.denyAttach() !== true) process.exit(72);',
        `const credentialText = fs.readFileSync(${JSON.stringify(credentialPath)}, "utf8");`,
        'const authority = credentialText.match(/^BRIDGE_AGENT_KEY=(.+)$/m)?.[1];',
        'if (!authority) process.exit(73);',
        'globalThis.__mcpParentAgentAuthority = authority;',
        'if (process.send) process.send({ ready: true });',
        'setInterval(() => {',
        '  if (!globalThis.__mcpParentAgentAuthority) process.exit(74);',
        '}, 1000);',
        "",
      ].join("\n"),
      { mode: 0o600 },
    );
    const helper = spawn(process.execPath, [protectedParentPath], {
      env: { PATH: process.env.PATH },
      stdio: ["ignore", "ignore", "ignore", "ipc"],
    });
    t.after(() => {
      if (helper.exitCode === null && helper.signalCode === null) helper.kill("SIGKILL");
      fs.rmSync(directory, { recursive: true, force: true });
    });
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        helper.kill("SIGKILL");
        reject(new Error("protected parent did not initialize"));
      }, 4_000);
      timeout.unref();
      helper.once("message", (message) => {
        if (
          typeof message === "object" &&
          message !== null &&
          "ready" in message &&
          message.ready === true
        ) {
          clearTimeout(timeout);
          resolve();
        }
      });
      helper.once("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      helper.once("exit", (code, signal) => {
        clearTimeout(timeout);
        reject(
          new Error(
            `protected parent exited before initialization (code=${code}, signal=${signal})`,
          ),
        );
      });
    });
    assert.ok(helper.pid);
    const baseline = spawnSync(
      "/bin/ps",
      ["eww", "-p", String(helper.pid)],
      { encoding: "utf8" },
    );
    assert.equal(baseline.status, 0, "same-user process baseline was unavailable");
    assert.equal(
      baseline.stdout.includes(agentKey),
      false,
      "AgentKey entered the protected parent's environment",
    );
    const lldbLookup = spawnSync("/usr/bin/xcrun", ["--find", "lldb"], {
      encoding: "utf8",
    });
    if (lldbLookup.status !== 0 || !lldbLookup.stdout.trim()) {
      t.skip("LLDB is unavailable for the real Mach task attach probe");
      return;
    }
    const lldbPath = lldbLookup.stdout.trim();
    const debugserverPath = path.resolve(
      path.dirname(lldbPath),
      "../../../SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver",
    );
    if (!fs.existsSync(debugserverPath)) {
      t.skip("debugserver is unavailable for the renamed debugger probe");
      return;
    }
    const renamedDebugserverPath = path.join(directory, "peer-authority-probe");
    fs.copyFileSync(debugserverPath, renamedDebugserverPath);
    fs.chmodSync(renamedDebugserverPath, 0o700);

    fs.writeFileSync(
      probePath,
      [
        'const crypto = require("node:crypto");',
        'const fs = require("node:fs");',
        'const { spawnSync } = require("node:child_process");',
        `const targetPid = ${helper.pid};`,
        `const expectedDigest = ${JSON.stringify(agentKeyDigest)};`,
        `const renamedDebugserverPath = ${JSON.stringify(renamedDebugserverPath)};`,
        'const ps = spawnSync("/bin/ps", ["eww", "-p", String(targetPid)], { encoding: "utf8", timeout: 2000 });',
        'const tokens = String(ps.stdout || "").split(/\\s+/);',
        'const childEnvHadAgentKey = Object.hasOwn(process.env, "BRIDGE_AGENT_KEY") || Object.hasOwn(process.env, "KNOCK_KNOCK_AGENT_KEY");',
        'const sawAgentKey = tokens.some((token) => {',
        '  const candidate = token.startsWith("BRIDGE_AGENT_KEY=") ? token.slice("BRIDGE_AGENT_KEY=".length) : token;',
        '  return crypto.createHash("sha256").update(candidate).digest("hex") === expectedDigest;',
        '});',
        `const attach = spawnSync(${JSON.stringify(lldbPath)}, ["--batch", "--attach-pid", String(targetPid), "-o", "process detach"], {`,
        '  encoding: "utf8",',
        '  timeout: 4000,',
        '  env: { ...process.env, LLDB_DEBUGSERVER_PATH: renamedDebugserverPath },',
        '});',
        'const attachOutput = String(attach.stdout || "") + "\\n" + String(attach.stderr || "");',
        'const attachDenied = /attach failed|unable to attach|operation not permitted|not permitted|permission denied/i.test(attachOutput);',
        'const stoppedExactTarget = new RegExp(`^Process ${targetPid} stopped\\\\r?$`, "m").test(attachOutput);',
        'const hasRealFrame = /^\\s*\\*?\\s*frame #0:\\s+0x[0-9a-f]+\\b/im.test(attachOutput);',
        'const attachSucceeded = attach.status === 0',
        '  && attach.signal === null',
        '  && attach.error === undefined',
        '  && !attachDenied',
        '  && stoppedExactTarget',
        '  && hasRealFrame;',
        `fs.writeFileSync(${JSON.stringify(resultPath)}, JSON.stringify({`,
        '  sawAgentKey,',
        '  childEnvHadAgentKey,',
        '  psStatus: ps.status,',
        '  attachSucceeded,',
        '}));',
        'process.exit(sawAgentKey || childEnvHadAgentKey || attachSucceeded ? 71 : 0);',
        "",
      ].join("\n"),
      { mode: 0o600 },
    );
    const child = spawnMacOSCredentialSandboxedProcess(
      process.execPath,
      [probePath],
      { env: { PATH: process.env.PATH }, detached: false },
      [credentialPath],
    );
    t.after(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    });
    const childResult = await new Promise<{
      code: number | null;
      signal: NodeJS.Signals | null;
    }>((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error("Seatbelt parent inspection probe did not exit"));
      }, 5_000);
      timeout.unref();
      child.once("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.once("close", (code, signal) => {
        clearTimeout(timeout);
        resolve({ code, signal });
      });
    });
    assert.equal(
      fs.existsSync(resultPath),
      true,
      "Seatbelt probe did not produce security evidence",
    );
    const probeResult = JSON.parse(fs.readFileSync(resultPath, "utf8")) as {
      sawAgentKey: boolean;
      childEnvHadAgentKey: boolean;
      psStatus: number | null;
      attachSucceeded: boolean;
    };
    assert.equal(probeResult.sawAgentKey, false);
    assert.equal(probeResult.childEnvHadAgentKey, false);
    assert.equal(probeResult.attachSucceeded, false);
    assert.equal(childResult.signal, null);
    assert.equal(
      childResult.code === 0 || childResult.code === 71,
      true,
      "Seatbelt probe exited outside the accepted success-or-policy-denial contract",
    );
  },
);

test("external settlement waits for an in-flight response to drain before terminating", async (t) => {
  const askId = "ask_external_settlement_0001";
  const sessionId = "ses_external_settlement_0001";
  let observations: PendingWakeAsk[] = [
    { ...wakeAsk(askId, "queued-v1"), sessionId },
  ];
  let broker: WakeCapabilityHandle | undefined;
  let releaseProgress!: () => void;
  let markProgressStarted!: () => void;
  const progressGate = new Promise<void>((resolve) => {
    releaseProgress = resolve;
  });
  const progressStarted = new Promise<void>((resolve) => {
    markProgressStarted = resolve;
  });
  let resolveTerminated!: () => void;
  const terminated = new Promise<void>((resolve) => {
    resolveTerminated = resolve;
  });
  class DrainAwareChild extends FakeWakeChild {
    kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
      const result = super.kill(signal);
      if (signal === "SIGTERM") resolveTerminated();
      return result;
    }
  }
  const child = new DrainAwareChild();
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    platform: "win32",
    pollPending: async () => observations,
    openWakeCapability: async () => {
      broker = await createWakeCapabilityBroker({
        askId,
        sessionId,
        requireAuthority: () => undefined,
        backendRequest: async (requestPath) => {
          if (requestPath === "/v1/agents/me/asks/claim") {
            return {
              asks: [
                {
                  ask_id: askId,
                  session_id: sessionId,
                  claim_token: "claim_external_real_secret",
                  claim_generation: 7,
                  listener_generation: 7,
                  answerable: true,
                },
              ],
            };
          }
          markProgressStarted();
          await progressGate;
          return { ok: true };
        },
      });
      return broker;
    },
    spawnProcess: (() => child) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(async () => {
    releaseProgress();
    runner.stop();
    if (broker) await broker.close();
  });

  await runner.pollNow();
  assert.ok(broker);
  const activeBroker = broker;
  const claimResponse = await fetch(
    `${activeBroker.brokerUrl}/v1/agents/me/asks/claim`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: activeBroker.capability,
      },
    },
  );
  const claimed = (await claimResponse.json()) as {
    asks: Array<Record<string, unknown>>;
  };
  const progressResponsePromise = fetch(
    `${activeBroker.brokerUrl}/v1/sessions/${sessionId}/progress`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: activeBroker.capability,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        status: "working",
        ask_id: askId,
        claim_token: claimed.asks[0].claim_token,
        listener_generation: 1,
      }),
    },
  );
  await progressStarted;
  observations = [
    {
      ...wakeAsk(askId, "answered-v2"),
      sessionId,
      terminal: true,
      wakeable: false,
    },
  ];
  await runner.pollNow();
  assert.deepEqual(child.signals, []);
  assert.equal(activeBroker.closed(), true);

  releaseProgress();
  const progressResponse = await progressResponsePromise;
  assert.equal(progressResponse.status, 200);
  assert.deepEqual(await progressResponse.json(), { ok: true });
  await terminated;
  assert.deepEqual(child.signals, ["SIGTERM"]);
  child.emit("close", 0, null);
});

test("a real child consumes ordinary info settlement before exiting naturally", async (t) => {
  const askId = "ask_real_consumer_0001";
  const sessionId = "ses_real_consumer_0001";
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-broker-ack-"));
  const acknowledgementPath = path.join(directory, "ack.json");
  const signalPath = path.join(directory, "signal.txt");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let broker: WakeCapabilityHandle | undefined;
  let childClose: Promise<{ code: number | null; signal: NodeJS.Signals | null }> | undefined;
  const runner = createCodexWakeRunner({
    chatId: THREAD_ID,
    platform: "win32",
    childTimeoutMs: 2_000,
    pollPending: async () => [
      { ...wakeAsk(askId, "queued-v1"), sessionId },
    ],
    openWakeCapability: async () => {
      broker = await createWakeCapabilityBroker({
        askId,
        sessionId,
        requireAuthority: () => undefined,
        backendRequest: async (requestPath) =>
          requestPath === "/v1/agents/me/asks/claim"
            ? {
                asks: [
                  {
                    ask_id: askId,
                    session_id: sessionId,
                    claim_token: "claim_real_child_secret",
                    claim_generation: 7,
                    listener_generation: 7,
                    answerable: true,
                  },
                ],
              }
            : { ok: true },
      });
      return broker;
    },
    spawnProcess: ((_command, _args, options) => {
      const script = `
        const fs = require("node:fs");
        process.once("SIGTERM", () => {
          fs.writeFileSync(${JSON.stringify(signalPath)}, "SIGTERM");
          process.exit(70);
        });
        (async () => {
          const base = process.env.KNOCK_KNOCK_WAKE_BROKER_URL;
          const capability = process.env.KNOCK_KNOCK_WAKE_CAPABILITY;
          const headers = { "X-Knock-Wake-Capability": capability };
          const claimResponse = await fetch(base + "/v1/agents/me/asks/claim", { method: "POST", headers });
          if (!claimResponse.ok) throw new Error("claim " + claimResponse.status);
          const claim = await claimResponse.json();
          const ask = claim.asks[0];
          const terminalResponse = await fetch(base + "/v1/sessions/${sessionId}/events", {
            method: "POST",
            headers: { ...headers, "content-type": "application/json" },
            body: JSON.stringify({
              status: "info",
              summary: "complete",
              ask_id: ${JSON.stringify(askId)},
              claim_token: ask.claim_token,
              generation: 1,
            }),
          });
          const terminalBody = await terminalResponse.text();
          if (!terminalResponse.ok || !terminalBody.includes('"ok":true')) {
            throw new Error("terminal " + terminalResponse.status);
          }
          fs.writeFileSync(${JSON.stringify(acknowledgementPath)}, terminalBody);
          await new Promise((resolve) => setTimeout(resolve, 25));
        })().catch((error) => {
          fs.writeFileSync(${JSON.stringify(acknowledgementPath)}, "ERROR:" + error.message);
          process.exitCode = 1;
        });
      `;
      const child = spawn(process.execPath, ["-e", script], {
        env: options.env,
        stdio: "ignore",
      });
      childClose = new Promise((resolve) => {
        child.once("close", (code, signal) => resolve({ code, signal }));
      });
      return child;
    }) as SpawnWakeProcess,
    logger: () => undefined,
  });
  t.after(async () => {
    runner.stop();
    if (broker) await broker.close();
  });

  await runner.pollNow();
  assert.ok(childClose);
  const result = await childClose;
  assert.deepEqual(result, { code: 0, signal: null });
  assert.equal(fs.existsSync(signalPath), false);
  assert.match(fs.readFileSync(acknowledgementPath, "utf8"), /"ok":true/);
  assert.equal(broker?.closed(), true);
  runner.stop();
});

test("fence and shutdown forcibly drain a stuck authenticated child before group TERM and KILL", async (t) => {
  const bounded = <T>(promise: Promise<T>, milliseconds: number) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(
        () => reject(new Error("stuck-child test timed out")),
        milliseconds,
      );
    });
    return Promise.race([promise, timeout]).finally(() => {
      if (timer) clearTimeout(timer);
    });
  };
  const waitForFile = async (filePath: string, milliseconds: number) => {
    const deadline = Date.now() + milliseconds;
    while (!fs.existsSync(filePath)) {
      if (Date.now() >= deadline) throw new Error("stuck-child marker timed out");
      await wait(2);
    }
  };
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-stuck-supervisor-"));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  for (const trigger of ["fence", "shutdown"] as const) {
    const askId = `ask_stuck_${trigger}`;
    const sessionId = `ses_stuck_${trigger}`;
    const holdingPath = path.join(directory, `${trigger}.holding`);
    const leaderPidPath = path.join(directory, `${trigger}.pid`);
    let broker: WakeCapabilityHandle | undefined;
    let childProcess: ReturnType<typeof spawn> | undefined;
    let childClose:
      | Promise<{ code: number | null; signal: NodeJS.Signals | null }>
      | undefined;
    const supervisorSignals: Array<{
      signal: NodeJS.Signals;
      at: number;
    }> = [];
    let legacyPgidOwner = "owned-supervisor";
    const legacyGroupSignals: Array<{
      owner: string;
      groupId: number;
      signal: NodeJS.Signals;
    }> = [];
    const runner = createCodexWakeRunner({
      chatId: THREAD_ID,
      platform: "darwin",
      brokerDrainTimeoutMs: 25,
      childKillGraceMs: 250,
      childTimeoutMs: 2_000,
      pollPending: async () => [
        { ...wakeAsk(askId, "queued-v1"), sessionId },
      ],
      openWakeCapability: async () => {
        broker = await createWakeCapabilityBroker({
          askId,
          sessionId,
          requireAuthority: () => undefined,
          backendRequest: async () => ({
            asks: [
              {
                ask_id: askId,
                session_id: sessionId,
                claim_token: `claim_stuck_${trigger}_secret`,
                claim_generation: 7,
                listener_generation: 7,
                answerable: true,
              },
            ],
          }),
        });
        return broker;
      },
      spawnProcess: ((_command, _args, options) => {
        const script = `
          const fs = require("node:fs");
          const net = require("node:net");
          process.on("SIGTERM", () => {});
          fs.writeFileSync(${JSON.stringify(leaderPidPath)}, String(process.pid));
          (async () => {
            const base = process.env.KNOCK_KNOCK_WAKE_BROKER_URL;
            const capability = process.env.KNOCK_KNOCK_WAKE_CAPABILITY;
            const claimResponse = await fetch(base + "/v1/agents/me/asks/claim", {
              method: "POST",
              headers: { "X-Knock-Wake-Capability": capability },
            });
            if (!claimResponse.ok) throw new Error("claim " + claimResponse.status);
            await claimResponse.json();
            const endpoint = new URL(base);
            const socket = net.createConnection({ host: endpoint.hostname, port: Number(endpoint.port) });
            socket.on("error", () => {});
            socket.on("close", () => {});
            socket.once("connect", () => {
              socket.write(
                "POST /v1/sessions/${sessionId}/progress HTTP/1.1\\r\\n" +
                "Host: " + endpoint.host + "\\r\\n" +
                "X-Knock-Wake-Capability: " + capability + "\\r\\n" +
                "Content-Type: application/json\\r\\n" +
                "Content-Length: 100000\\r\\n" +
                "Connection: keep-alive\\r\\n\\r\\n" +
                '{"status":"working"'
              );
              setTimeout(
                () => fs.writeFileSync(${JSON.stringify(holdingPath)}, "holding"),
                20,
              );
            });
            setInterval(() => {}, 1000);
          })().catch(() => process.exit(71));
        `;
        const invocation = buildCodexWakeSupervisorInvocation(
          process.execPath,
          ["-e", script],
          50,
        );
        const child = spawn(invocation.command, [...invocation.args], {
          env: options.env,
          detached: options.detached,
          stdio: "ignore",
        });
        const killSupervisor = child.kill.bind(child);
        child.kill = ((signal?: NodeJS.Signals | number) => {
          if (typeof signal === "string") {
            supervisorSignals.push({ signal, at: Date.now() });
          }
          return killSupervisor(signal);
        }) as typeof child.kill;
        childProcess = child;
        childClose = new Promise((resolve) => {
          child.once("close", (code, signal) => resolve({ code, signal }));
        });
        return child;
      }) as SpawnWakeProcess,
      signalProcessGroup: (groupId: number, signal: NodeJS.Signals) => {
        legacyGroupSignals.push({ owner: legacyPgidOwner, groupId, signal });
        return true;
      },
      logger: () => undefined,
    } as Parameters<typeof createCodexWakeRunner>[0] & {
      signalProcessGroup: (groupId: number, signal: NodeJS.Signals) => boolean;
    });

    try {
      await runner.pollNow();
      await waitForFile(holdingPath, 1_000);
      assert.ok(broker);
      assert.ok(childProcess?.pid);
      assert.equal(broker.hasActiveResponse(), true);
      const triggeredAt = Date.now();
      if (trigger === "fence") runner.revoke();
      else runner.stop();

      assert.ok(childClose);
      const result = await bounded(childClose, 2_000);
      assert.deepEqual(
        result,
        { code: 1, signal: null },
      );
      assert.deepEqual(
        supervisorSignals.map(({ signal }) => signal),
        ["SIGTERM"],
      );
      assert.ok(supervisorSignals[0].at - triggeredAt >= 20);
      const leaderPid = Number(fs.readFileSync(leaderPidPath, "utf8"));
      assert.equal(processIdentityExists(leaderPid), false);
      assert.deepEqual(legacyGroupSignals, []);
      legacyPgidOwner = "unrelated-reused-pgid";
      await wait(275);
      assert.deepEqual(legacyGroupSignals, []);
      await bounded(broker.close(), 1_000);
      assert.equal(broker.closed(), true);
      assert.equal(broker.hasActiveResponse(), false);
      assert.deepEqual(runner.snapshot(), { state: "fenced", askCount: 0 });
    } finally {
      runner.stop();
      if (
        childProcess &&
        childProcess.exitCode === null &&
        childProcess.signalCode === null
      ) {
        childProcess.kill("SIGKILL");
      }
      if (broker) await broker.close();
    }
  }
});

test("capability child never registers or renews and stale or expired capabilities fail closed", async (t) => {
  const localCapability = testWakeCapability();
  const config = wakeCapabilityClientConfig({
    [WAKE_BROKER_URL_ENV]: localCapability.brokerUrl,
    [WAKE_BROKER_CAPABILITY_ENV]: localCapability.capability,
  });
  assert.ok(config);
  let acquisitions = 0;
  let renewals = 0;
  const childListener = startListeningHeartbeat(
    {
      acquire: async () => {
        acquisitions += 1;
        return leaseResponse;
      },
      renew: async () => {
        renewals += 1;
        return leaseResponse;
      },
    },
    { inheritedFence: wakeCapabilityLocalFence(config), intervalMs: 5 },
  );
  t.after(() => childListener.stop());
  await wait(12);
  assert.equal(acquisitions, 0);
  assert.equal(renewals, 0);
  assert.doesNotThrow(() => requireActiveLeaseV2Authority(childListener.status()));
  childListener.stop();

  const parent = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  t.after(() => parent.stop());
  await wait(1);
  const staleBroker = await createWakeCapabilityBroker({
    askId: "ask_stale",
    sessionId: "ses_stale",
    requireAuthority: () => requireActiveLeaseV2Authority(parent.status()),
    backendRequest: async () => {
      revokeListenerAuthorityForApiResponse(409, '{"code":"lease_fenced"}');
      throw new Error("409 lease_fenced");
    },
  });
  t.after(() => staleBroker.close());
  const staleTerminal = new Promise<void>((resolve) => {
    staleBroker.onTerminal(resolve);
  });
  const staleResponse = await fetch(
    `${staleBroker.brokerUrl}/v1/agents/me/asks/claim`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: staleBroker.capability,
      },
    },
  );
  assert.equal(staleResponse.status, 409);
  assert.doesNotMatch(await staleResponse.text(), /lease_final_blockers_123/);
  await staleTerminal;
  assert.equal(staleBroker.closed(), true);
  assert.equal(parent.status().fenced, true);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  parent.stop();

  let clock = 1_000;
  let expiredBackendCalls = 0;
  const expiredBroker = await createWakeCapabilityBroker({
    askId: "ask_expired",
    sessionId: "ses_expired",
    ttlMs: 50,
    now: () => clock,
    requireAuthority: () => undefined,
    backendRequest: async () => {
      expiredBackendCalls += 1;
      return {};
    },
  });
  t.after(() => expiredBroker.close());
  clock = 1_051;
  const expiredTerminal = new Promise<void>((resolve) => {
    expiredBroker.onTerminal(resolve);
  });
  const expiredResponse = await fetch(
    `${expiredBroker.brokerUrl}/v1/agents/me/asks/claim`,
    {
      method: "POST",
      headers: {
        [WAKE_BROKER_CAPABILITY_HEADER]: expiredBroker.capability,
      },
    },
  );
  assert.equal(expiredResponse.status, 410);
  await expiredTerminal;
  assert.equal(expiredBroker.closed(), true);
  assert.equal(expiredBackendCalls, 0);
  assert.equal(isLoopbackWakePeer("127.0.0.1"), true);
  assert.equal(isLoopbackWakePeer("::1"), true);
  assert.equal(isLoopbackWakePeer("10.0.0.7"), false);
});

test("wake capabilities are recursively redacted from diagnostics and errors", () => {
  const capability = "capability_value_that_must_never_escape_123456789";
  const diagnostic = JSON.stringify(
    sanitizeSensitiveData({
      wake_capability: capability,
      nested: { KNOCK_KNOCK_WAKE_CAPABILITY: capability },
    }),
  );
  assert.doesNotMatch(diagnostic, new RegExp(capability));
  assert.doesNotMatch(
    safeErrorMessage(`wake_capability=${capability}`),
    new RegExp(capability),
  );
});

test("environment classification accepts only canonical Staging and Production identities", () => {
  assert.equal(apiEnvironmentId(KNOCK_KNOCK_STAGING_API_ORIGIN), "staging");
  assert.equal(apiEnvironmentId(KNOCK_KNOCK_PRODUCTION_API_ORIGIN), "production");

  const canonicalLocalIdentity = "local|http:|loopback|8787|/";
  assert.equal(apiEnvironmentId("http://localhost:8787"), canonicalLocalIdentity);
  assert.equal(apiEnvironmentId("http://127.0.0.1:8787"), canonicalLocalIdentity);
  assert.equal(apiEnvironmentId("http://[::1]:8787"), canonicalLocalIdentity);
  assert.equal(
    apiEnvironmentId("http://localhost:8787/bridge/"),
    "local|http:|loopback|8787|/bridge",
  );
  assert.equal(
    sameApiEnvironment(
      "http://localhost:8787/bridge/",
      "http://127.0.0.1:8787/bridge",
    ),
    true,
  );
  assert.equal(
    sameApiEnvironment(
      "http://127.0.0.1:8787/bridge",
      "http://[::1]:8787/bridge",
    ),
    true,
  );
  assert.equal(
    sameApiEnvironment("http://localhost:8787", "http://127.0.0.1:8788"),
    false,
  );
  assert.equal(
    sameApiEnvironment("http://localhost:8787", "https://127.0.0.1:8787"),
    false,
  );
  assert.equal(
    sameApiEnvironment(
      "http://localhost:8787/bridge",
      "http://127.0.0.1:8787/other",
    ),
    false,
  );
  assert.match(apiEnvironmentId("http://dev.localhost:8787"), /^custom:/);

  const lookalikes = [
    "https://knock-knock-backend-staging.wch-klaus.workers.dev.evil.test",
    "https://knock-knock-backend-staging.evil.test",
    "https://production-knock-knock.attacker.test",
    "https://knock-knock-backend.wch-klaus.workers.dev",
    `${KNOCK_KNOCK_STAGING_API_ORIGIN}:444`,
    `${KNOCK_KNOCK_STAGING_API_ORIGIN}/proxy`,
  ];
  for (const lookalike of lookalikes) {
    assert.match(apiEnvironmentId(lookalike), /^custom:/);
    assert.equal(sameApiEnvironment(lookalike, KNOCK_KNOCK_STAGING_API_ORIGIN), false);
  }

  const hostileCredential = selectBoundAgentCredentials({
    requestedApiUrl: KNOCK_KNOCK_STAGING_API_ORIGIN,
    files: [
      {
        path: "/tmp/hostile.env",
        text:
          "KNOCK_KNOCK_API_URL=https://knock-knock-backend-staging.evil.test\n" +
          "BRIDGE_AGENT_KEY=vak_hostile_secret\n",
      },
    ],
  });
  assert.equal("agentKey" in hostileCredential, false);
});

test("selected custom agent env path remains parent-only and is never forwarded", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-custom-env-"));
  const envPath = path.join(directory, "selected-agent.env");
  const missingPath = path.join(directory, "missing.env");
  fs.writeFileSync(envPath, "BRIDGE_AGENT_KEY=not-copied\n");
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const env = buildCodexWakeEnvironment(
    THREAD_ID,
    {
      PATH: "/bin",
      KNOCK_KNOCK_API_URL: KNOCK_KNOCK_STAGING_API_ORIGIN,
      KNOCK_KNOCK_AGENT_ENV: missingPath,
      KNOCK_KNOCK_AGENT_KEY: "parent-secret",
    },
    testWakeCapability(),
  );
  assert.equal(env.KNOCK_KNOCK_AGENT_ENV, undefined);
  assert.equal(env.KNOCK_KNOCK_LISTENER_INSTANCE_ID, undefined);
  assert.equal(env.KNOCK_KNOCK_API_URL, undefined);
  assert.equal(env.KNOCK_KNOCK_AGENT_KEY, undefined);
  assert.equal(env[WAKE_BROKER_URL_ENV], "http://127.0.0.1:43124");
  assert.equal(env[WAKE_BROKER_CAPABILITY_ENV], TEST_WAKE_CAPABILITY);
  assert.doesNotMatch(JSON.stringify(env), new RegExp(`${envPath}|${missingPath}|parent-secret`));
});

test("wake prompt and MCP contract expose POST claim internally with no claim argument", () => {
  const contractPath = fileURLToPath(
    new URL("../../../contracts/schemas/mcp-tools.json", import.meta.url),
  );
  const contractText = fs.readFileSync(contractPath, "utf8");
  const contract = JSON.parse(contractText) as {
    tools: Array<{
      name: string;
      description?: string;
      input?: {
        additionalProperties?: boolean;
        properties?: Record<string, { enum?: string[] }>;
      };
    }>;
  };
  const getUserAsks = contract.tools.find((tool) => tool.name === "get_user_asks");
  const updateProgress = contract.tools.find((tool) => tool.name === "update_progress");
  const reportEvent = contract.tools.find((tool) => tool.name === "report_event");
  assert.ok(getUserAsks);
  assert.ok(updateProgress);
  assert.ok(reportEvent);
  assert.equal(getUserAsks.input?.properties?.claim, undefined);
  assert.equal(getUserAsks.input?.additionalProperties, false);
  assert.ok(updateProgress.input?.properties?.ask_id);
  assert.equal(updateProgress.input?.additionalProperties, false);
  assert.deepEqual(reportEvent.input?.properties?.status?.enum, [
    "info",
    "needs_user",
    "succeeded",
    "failed",
  ]);
  assert.ok(reportEvent.input?.properties?.ask_id);
  assert.ok(reportEvent.input?.properties?.in_reply_to_ask_id);
  assert.equal(reportEvent.input?.additionalProperties, false);
  assert.match(getUserAsks.description ?? "", /POST \/v1\/agents\/me\/asks\/claim/);
  assert.doesNotMatch(contractText, /claim=true/);
  assert.doesNotMatch(CODEX_WAKE_PROMPT, /claim=true/);
  assert.match(CODEX_WAKE_PROMPT, /passive read-only/);
});

test("takeover remains explicit and survives launcher restart normalization", () => {
  assert.equal(
    listenerTakeoverRequested({ KNOCK_KNOCK_LISTENER_TAKEOVER: "true" }),
    true,
  );
  assert.equal(listenerTakeoverRequested({}), false);
  assert.equal(
    listenerTakeoverRequested({ KNOCK_KNOCK_LISTENER_TAKEOVER: "false" }),
    false,
  );

  const launcherPath = fileURLToPath(
    new URL("../../../scripts/knock-codex-listener.sh", import.meta.url),
  );
  const result = spawnSync(
    "bash",
    [
      "-c",
      'source "$1"; export KNOCK_KNOCK_LISTENER_TAKEOVER=true; normalize_listener_takeover; first="$KNOCK_KNOCK_LISTENER_TAKEOVER"; normalize_listener_takeover; printf "%s:%s" "$first" "$KNOCK_KNOCK_LISTENER_TAKEOVER"',
      "bash",
      launcherPath,
    ],
    { encoding: "utf8", env: { PATH: process.env.PATH ?? "/usr/bin:/bin" } },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "true:true");
});

test("listener launcher resolves this checkout and executes its declared MCP runner", (t) => {
  const launcherPath = fileURLToPath(
    new URL("../../../scripts/knock-codex-listener.sh", import.meta.url),
  );
  const repositoryRoot = fs.realpathSync(
    fileURLToPath(new URL("../../../", import.meta.url)),
  );
  const source = fs.readFileSync(launcherPath, "utf8");
  assert.doesNotMatch(source, /\/Users\//);
  assert.doesNotMatch(source, /\.worktrees\//);
  assert.doesNotMatch(source, /NODE_PATH/);
  assert.match(source, /repository_root/);
  assert.match(source, /--filter @vab\/mcp/);

  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "vab-launcher-"));
  const binDirectory = path.join(directory, "bin");
  const capturePath = path.join(directory, "capture.txt");
  const envPath = path.join(directory, "agent.env");
  fs.mkdirSync(binDirectory);
  fs.writeFileSync(envPath, "BRIDGE_AGENT_KEY=file-only-key\n");
  fs.writeFileSync(path.join(binDirectory, "codex"), "#!/bin/sh\nexit 0\n", {
    mode: 0o755,
  });
  fs.writeFileSync(
    path.join(binDirectory, "pnpm"),
    [
      "#!/bin/sh",
      'printf "%s\\n" "$@" > "$VAB_CAPTURE"',
      'printf "takeover=%s\\n" "${KNOCK_KNOCK_LISTENER_TAKEOVER-unset}" >> "$VAB_CAPTURE"',
      'printf "bridge_key=%s\\n" "${BRIDGE_AGENT_KEY-unset}" >> "$VAB_CAPTURE"',
      'printf "agent_key=%s\\n" "${KNOCK_KNOCK_AGENT_KEY-unset}" >> "$VAB_CAPTURE"',
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 },
  );
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const result = spawnSync("bash", [launcherPath], {
    encoding: "utf8",
    env: {
      PATH: `${binDirectory}:/usr/bin:/bin`,
      CODEX_THREAD_ID: THREAD_ID,
      KNOCK_KNOCK_AGENT_ENV: envPath,
      KNOCK_KNOCK_LISTENER_TAKEOVER: "true",
      KNOCK_KNOCK_AGENT_KEY: "must-not-survive",
      BRIDGE_AGENT_KEY: "must-not-survive",
      VAB_CAPTURE: capturePath,
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const capture = fs.readFileSync(capturePath, "utf8");
  assert.match(capture, new RegExp(`--dir\\n${repositoryRoot.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&")}\\n`));
  assert.match(capture, /--filter\n@vab\/mcp\nexec\ntsx\n--no-warnings\nsrc\/codex-listener\.ts\n/);
  assert.match(capture, /takeover=true/);
  assert.match(capture, /bridge_key=unset/);
  assert.match(capture, /agent_key=unset/);
});

test("lease-loss API responses revoke all listener and Ask authority exactly once", async () => {
  resetAskClaimState();
  const handle = startListeningHeartbeat(
    {
      acquire: async () => leaseResponse,
      renew: async () => leaseResponse,
    },
    { intervalMs: 60_000 },
  );
  await wait(0);
  trackAgentAskResponse({ asks: [claimAsk("claim_revoke_0001")] });
  let wakeRevocations = 0;
  const unsubscribe = onListenerAuthorityRevoked(() => {
    wakeRevocations += 1;
  });

  revokeListenerAuthorityForApiResponse(500, '{"code":"temporary"}');
  assert.equal(listenerAuthorityIsRevoked(), false);
  revokeListenerAuthorityForApiResponse(409, '{"code":"lease_fenced"}');
  revokeListenerAuthorityForApiResponse(401, '{"code":"invalid_agent_key"}');

  assert.equal(listenerAuthorityIsRevoked(), true);
  assert.equal(wakeRevocations, 1);
  assert.equal(listenerHeaders()["X-Knock-Listener-Lease-ID"], undefined);
  assert.equal(getAskClaimStatus("ask_owner_0001"), undefined);
  assert.equal(handle.status().fenced, true);
  assert.throws(
    () => requireActiveLeaseV2Authority(handle.status()),
    /listener_authority_revoked/,
  );
  unsubscribe();
  handle.stop();
});
