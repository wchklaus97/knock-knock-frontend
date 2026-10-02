import {
  WAKE_BROKER_CAPABILITY_ENV,
  WAKE_BROKER_URL_ENV,
  wakeCapabilityClientConfig,
} from "./wake-capability.js";
import type { WakeCapabilityHandle } from "./wake-capability-broker.js";
import { scrubAgentCredentialEnvironment } from "./cli-support.js";
import { spawnMacOSCredentialSandboxedProcess } from "./macos-wake-sandbox.js";

export const CODEX_WAKE_PROMPT =
  "A passive read-only GET /v1/agents/me/asks observed a phone Ask for this Codex Task. Call the configured MCP get_user_asks tool without a claim argument; that tool internally claims through POST /v1/agents/me/asks/claim. Process the returned Ask and answer it through report_event using MCP-managed claim-v2 credentials. Retrieve all Ask content through MCP only; do not infer content from this wake prompt and do not expose transcript, claim, or lease credentials.";

export type CodexWakeState =
  | "idle"
  | "waking"
  | "working"
  | "backoff"
  | "exhausted"
  | "fenced";

export type CodexWakeSnapshot = Readonly<{
  state: CodexWakeState;
  askCount: number;
}>;

export type PendingWakeAsk = Readonly<{
  askId: string;
  clientTurnId?: string;
  sessionId?: string;
  revision: string;
  authorityGeneration?: number;
  legacyDrain?: boolean;
  wakeable?: boolean;
  terminal?: boolean;
}>;

export type WakeChild = {
  readonly pid?: number;
  once(event: "spawn", listener: () => void): WakeChild;
  once(event: "error", listener: (error: Error) => void): WakeChild;
  once(
    event: "exit",
    listener: (code: number | null, signal: NodeJS.Signals | null) => void,
  ): WakeChild;
  once(
    event: "close",
    listener: (code: number | null, signal: NodeJS.Signals | null) => void,
  ): WakeChild;
  kill(signal?: NodeJS.Signals): boolean;
};

export type SpawnWakeProcess = (
  command: string,
  args: readonly string[],
  options: { stdio: "ignore"; env: NodeJS.ProcessEnv; detached: boolean },
) => WakeChild;

export type WakeSupervisorInvocation = Readonly<{
  command: string;
  args: readonly string[];
}>;

export type CodexWakeRunnerOptions = {
  chatId: string;
  pollPending: () => Promise<readonly PendingWakeAsk[]>;
  spawnProcess?: SpawnWakeProcess;
  parentEnv?: NodeJS.ProcessEnv;
  credentialPaths?: readonly string[];
  openWakeCapability?: (ask: PendingWakeAsk) => Promise<WakeCapabilityHandle>;
  pollIntervalMs?: number;
  backoffBaseMs?: number;
  backoffMaxMs?: number;
  maxWakeAttemptsPerAsk?: number;
  childTimeoutMs?: number;
  childKillGraceMs?: number;
  brokerDrainTimeoutMs?: number;
  platform?: NodeJS.Platform;
  now?: () => number;
  logger?: (message: string) => void;
  onFatal?: () => void;
};

export type CodexWakeRunner = {
  start: () => void;
  stop: () => void;
  pollNow: () => Promise<void>;
  revoke: () => void;
  snapshot: () => CodexWakeSnapshot;
};

type AskWakeRecord = {
  askId: string;
  clientTurnId?: string;
  revision: string;
  authorityGeneration?: number;
  attempts: number;
  cooldownUntil: number;
  awaitingSettlementObservation: boolean;
  unsettledSuccessfulExits: number;
  terminal: boolean;
  lastSeenSequence: number;
};

type ActiveWakeChild = {
  process: WakeChild;
  identityKey: string;
  authorityGeneration?: number;
  staleGeneration: boolean;
  finished: boolean;
  terminating: boolean;
  drainTerminationPending: boolean;
  timeoutTimer?: ReturnType<typeof setTimeout>;
  killTimer?: ReturnType<typeof setTimeout>;
  wakeCapability: WakeCapabilityHandle;
  capabilityClosed: boolean;
  unsubscribeCapabilityTerminal?: () => void;
  finish: (succeeded: boolean) => void;
};

const UUID_LIKE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_TRACKED_WAKE_ASKS = 256;

export const CODEX_WAKE_ENV_ALLOWLIST = Object.freeze([
  "PATH",
  "HOME",
  "TMPDIR",
  "USER",
  "LOGNAME",
  "SHELL",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "CODEX_HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_CACHE_HOME",
  "NO_COLOR",
] as const);

const CODEX_WAKE_SENTINEL_SOURCE = String.raw`
"use strict";
const { spawn } = require("node:child_process");
const [command, ...args] = process.argv.slice(1);

const signalOwnedGroup = (signal) => {
  try {
    process.kill(-process.pid, signal);
  } catch (error) {
    if (!error || error.code !== "ESRCH") process.exitCode = 1;
  }
};

process.on("SIGTERM", () => undefined);
process.on("SIGINT", () => undefined);
process.on("SIGHUP", () => undefined);
process.on("message", (message) => {
  if (
    !message ||
    message.type !== "signal" ||
    (message.signal !== "SIGTERM" && message.signal !== "SIGKILL")
  ) {
    return;
  }
  signalOwnedGroup(message.signal);
});
process.on("disconnect", () => signalOwnedGroup("SIGKILL"));
process.on("uncaughtException", () => signalOwnedGroup("SIGKILL"));

let reported = false;
const reportLeaderExit = (code, signal) => {
  if (reported) return;
  reported = true;
  if (!process.connected) {
    signalOwnedGroup("SIGKILL");
    return;
  }
  process.send({
    type: "leader-exit",
    succeeded: code === 0 && signal === null,
  });
};

let leader;
try {
  leader = spawn(command, args, {
    stdio: "ignore",
    env: process.env,
  });
} catch {
  reportLeaderExit(1, null);
}
if (leader) {
  leader.once("error", () => reportLeaderExit(1, null));
  leader.once("exit", (code, signal) => reportLeaderExit(code, signal));
}
`;

const CODEX_WAKE_SUPERVISOR_SOURCE = String.raw`
"use strict";
const { spawn } = require("node:child_process");
const [sentinelSource, graceRaw, command, ...args] = process.argv.slice(1);
const parsedGrace = Number(graceRaw);
const graceMs =
  Number.isSafeInteger(parsedGrace) && parsedGrace > 0 ? parsedGrace : 5000;

let sentinel;
let sentinelExited = false;
let draining = false;
let finished = false;
let leaderSucceeded = false;
let killTimer;

const finish = (succeeded) => {
  if (finished) return;
  finished = true;
  if (killTimer) clearTimeout(killTimer);
  process.exit(succeeded ? 0 : 1);
};

const disconnectOwnedSentinel = () => {
  if (!sentinel || sentinelExited || !sentinel.connected) return;
  try {
    sentinel.disconnect();
  } catch {
    // IPC teardown still converges through the sentinel close/error handlers.
  }
};

const sendOwnedSignal = (signal) => {
  if (!sentinel || sentinelExited || !sentinel.connected) return false;
  try {
    sentinel.send({ type: "signal", signal }, (error) => {
      if (error) disconnectOwnedSentinel();
    });
    return true;
  } catch {
    disconnectOwnedSentinel();
    return false;
  }
};

const drain = (succeeded, delayMs) => {
  if (draining) return;
  draining = true;
  leaderSucceeded = succeeded;
  if (!sendOwnedSignal("SIGTERM")) {
    if (sentinelExited) finish(succeeded);
    else disconnectOwnedSentinel();
    return;
  }
  const force = () => {
    if (sentinelExited) return;
    if (!sendOwnedSignal("SIGKILL")) disconnectOwnedSentinel();
  };
  if (delayMs <= 0) {
    force();
  } else {
    killTimer = setTimeout(force, delayMs);
  }
};

try {
  sentinel = spawn(
    process.execPath,
    ["-e", sentinelSource, command, ...args],
    {
      detached: true,
      stdio: ["ignore", "ignore", "ignore", "ipc"],
      env: process.env,
    },
  );
} catch {
  finish(false);
}

if (sentinel) {
  sentinel.on("message", (message) => {
    if (message && message.type === "leader-exit") {
      drain(message.succeeded === true, graceMs);
    }
  });
  sentinel.once("error", () => {
    if (sentinel.pid === undefined) {
      sentinelExited = true;
      finish(false);
      return;
    }
    drain(false, 0);
  });
  sentinel.once("exit", () => {
    sentinelExited = true;
  });
  sentinel.once("close", () => {
    sentinelExited = true;
    finish(draining && leaderSucceeded);
  });
}

const cancel = () => drain(false, 0);
process.on("SIGTERM", cancel);
process.on("SIGINT", cancel);
process.on("SIGHUP", cancel);
`;

export function buildCodexWakeSupervisorInvocation(
  command: string,
  args: readonly string[],
  childKillGraceMs: number,
  runtimePath = process.execPath,
): WakeSupervisorInvocation {
  if (
    !command ||
    !runtimePath ||
    !Number.isSafeInteger(childKillGraceMs) ||
    childKillGraceMs <= 0
  ) {
    throw new Error("Codex wake supervisor configuration is invalid");
  }
  return Object.freeze({
    command: runtimePath,
    args: Object.freeze([
      "-e",
      CODEX_WAKE_SUPERVISOR_SOURCE,
      CODEX_WAKE_SENTINEL_SOURCE,
      String(childKillGraceMs),
      command,
      ...args,
    ]),
  });
}

function defaultSpawnProcess(
  command: string,
  args: readonly string[],
  options: { stdio: "ignore"; env: NodeJS.ProcessEnv; detached: boolean },
  platform: NodeJS.Platform,
  credentialPaths: readonly string[],
  childKillGraceMs: number,
): WakeChild {
  if (platform !== "darwin") {
    throw new Error("Codex wake credential isolation requires macOS Seatbelt");
  }
  const supervisor = buildCodexWakeSupervisorInvocation(
    command,
    args,
    childKillGraceMs,
  );
  return spawnMacOSCredentialSandboxedProcess(
    supervisor.command,
    supervisor.args,
    { env: options.env, detached: options.detached },
    credentialPaths,
  ) as unknown as WakeChild;
}

function validateCodexThreadId(value: string): string {
  const chatId = value.trim();
  if (
    !chatId ||
    chatId.length > 128 ||
    chatId.startsWith("-") ||
    /[\u0000-\u001f\u007f]/.test(chatId) ||
    !UUID_LIKE.test(chatId)
  ) {
    throw new Error(
      "CODEX_THREAD_ID or KNOCK_KNOCK_CHAT_ID must be a UUID-like Codex thread id and must not start with '-'",
    );
  }
  return chatId;
}

export function resolveCodexWakeChatId(env: NodeJS.ProcessEnv = process.env): string {
  const codexThreadId = env.CODEX_THREAD_ID?.trim();
  if (codexThreadId) return validateCodexThreadId(codexThreadId);
  return validateCodexThreadId(env.KNOCK_KNOCK_CHAT_ID ?? "");
}

function isSensitiveWakeEnvName(name: string): boolean {
  return /(?:key|token|secret|credential|authorization|password|transcript|claim|lease)/i.test(
    name,
  );
}

function scrubCodexWakeEnvironment(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  scrubAgentCredentialEnvironment(env);
  for (const name of Object.keys(env)) {
    if (
      name !== WAKE_BROKER_URL_ENV &&
      name !== WAKE_BROKER_CAPABILITY_ENV &&
      isSensitiveWakeEnvName(name)
    ) {
      delete env[name];
    }
  }
  return env;
}

export function buildCodexWakeEnvironment(
  chatIdInput: string,
  parentEnv: NodeJS.ProcessEnv = process.env,
  wakeCapability?: Pick<WakeCapabilityHandle, "brokerUrl" | "capability">,
): NodeJS.ProcessEnv {
  const chatId = validateCodexThreadId(chatIdInput);
  const childEnv: NodeJS.ProcessEnv = {};
  for (const name of CODEX_WAKE_ENV_ALLOWLIST) {
    if (isSensitiveWakeEnvName(name)) continue;
    const value = parentEnv[name];
    if (typeof value === "string" && value.length > 0) childEnv[name] = value;
  }
  childEnv.CODEX_THREAD_ID = chatId;

  if (!wakeCapability) throw new Error("wake capability unavailable");
  const validated = wakeCapabilityClientConfig({
    [WAKE_BROKER_URL_ENV]: wakeCapability.brokerUrl,
    [WAKE_BROKER_CAPABILITY_ENV]: wakeCapability.capability,
  });
  if (!validated) throw new Error("wake capability unavailable");
  childEnv[WAKE_BROKER_URL_ENV] = validated.brokerUrl;
  childEnv[WAKE_BROKER_CAPABILITY_ENV] = validated.capability;
  return scrubCodexWakeEnvironment(childEnv);
}

function scalarRevisionValue(value: unknown): string | number | boolean | null | undefined {
  return value === null ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
    ? value
    : undefined;
}

export function pendingWakeAsksFromResponse(response: unknown): PendingWakeAsk[] {
  if (!response || typeof response !== "object" || Array.isArray(response)) return [];
  const asks = (response as Record<string, unknown>).asks;
  if (!Array.isArray(asks)) return [];

  const pending: PendingWakeAsk[] = [];
  const seen = new Set<string>();
  for (const rawAsk of asks) {
    if (pending.length >= MAX_TRACKED_WAKE_ASKS) break;
    if (!rawAsk || typeof rawAsk !== "object" || Array.isArray(rawAsk)) continue;
    const ask = rawAsk as Record<string, unknown>;
    const askId = typeof ask.ask_id === "string" ? ask.ask_id.trim() : "";
    if (
      !askId ||
      askId.length > 256 ||
      /[\u0000-\u001f\u007f]/.test(askId) ||
      seen.has(askId)
    ) {
      continue;
    }
    seen.add(askId);
    const clientTurnId =
      typeof ask.client_turn_id === "string" && ask.client_turn_id.trim()
        ? ask.client_turn_id.trim()
        : undefined;
    const sessionId =
      typeof ask.session_id === "string" && ask.session_id.trim()
        ? ask.session_id.trim()
        : undefined;
    const terminal =
      ask.answered_at != null ||
      ask.status === "answered" ||
      ask.status === "settled" ||
      ask.status === "cancelled";
    const legacyDrain =
      ask.legacy_drain === true || ask.claim_state === "legacy-drain";
    const authorityGeneration =
      typeof ask.claim_generation === "number" &&
      Number.isSafeInteger(ask.claim_generation) &&
      ask.claim_generation > 0
        ? ask.claim_generation
        : undefined;
    const revision = JSON.stringify({
      clientTurnId: scalarRevisionValue(ask.client_turn_id),
      turnSequence: scalarRevisionValue(ask.turn_sequence),
      status: scalarRevisionValue(ask.status),
      updatedAt: scalarRevisionValue(ask.updated_at),
      answeredAt: scalarRevisionValue(ask.answered_at),
      claimGeneration: scalarRevisionValue(ask.claim_generation),
      listenerGeneration: scalarRevisionValue(ask.listener_generation),
      answerable: scalarRevisionValue(ask.answerable),
      legacyDrain,
      pollIdentity: scalarRevisionValue(ask.poll_identity),
    });
    pending.push({
      askId,
      clientTurnId,
      sessionId,
      revision,
      authorityGeneration,
      legacyDrain,
      wakeable: !terminal && !legacyDrain && ask.answerable !== false,
      terminal,
    });
  }
  return pending;
}

export function isWakeLeaseFencedError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\blease_fenced\b/i.test(message);
}

function normalizedPollAsks(
  asks: readonly PendingWakeAsk[],
): PendingWakeAsk[] {
  const normalized: PendingWakeAsk[] = [];
  const seen = new Set<string>();
  for (const ask of asks) {
    if (normalized.length >= MAX_TRACKED_WAKE_ASKS) break;
    const askId = typeof ask?.askId === "string" ? ask.askId.trim() : "";
    const clientTurnId =
      typeof ask?.clientTurnId === "string" && ask.clientTurnId.trim()
        ? ask.clientTurnId.trim()
        : undefined;
    const sessionId =
      typeof ask?.sessionId === "string" && ask.sessionId.trim()
        ? ask.sessionId.trim()
        : undefined;
    const revision = typeof ask?.revision === "string" ? ask.revision : "";
    const authorityGeneration =
      typeof ask?.authorityGeneration === "number" &&
      Number.isSafeInteger(ask.authorityGeneration) &&
      ask.authorityGeneration > 0
        ? ask.authorityGeneration
        : undefined;
    if (
      !askId ||
      askId.length > 256 ||
      !revision ||
      revision.length > 2_048 ||
      seen.has(askId)
    ) {
      continue;
    }
    seen.add(askId);
    normalized.push({
      askId,
      clientTurnId,
      sessionId,
      revision,
      authorityGeneration,
      legacyDrain: ask.legacyDrain === true,
      wakeable: ask.wakeable !== false && ask.terminal !== true,
      terminal: ask.terminal === true,
    });
  }
  return normalized;
}

function unrefTimer(timer: ReturnType<typeof setTimeout>): void {
  if (typeof timer === "object" && "unref" in timer) timer.unref();
}

export function createCodexWakeRunner(options: CodexWakeRunnerOptions): CodexWakeRunner {
  const chatId = validateCodexThreadId(options.chatId);
  const pollIntervalMs = options.pollIntervalMs ?? 3_000;
  if (!Number.isSafeInteger(pollIntervalMs) || pollIntervalMs < 2_000 || pollIntervalMs > 5_000) {
    throw new Error("Codex wake poll interval must be between 2000 and 5000 milliseconds");
  }
  const backoffBaseMs = options.backoffBaseMs ?? 2_000;
  const backoffMaxMs = options.backoffMaxMs ?? 30_000;
  if (
    !Number.isSafeInteger(backoffBaseMs) ||
    !Number.isSafeInteger(backoffMaxMs) ||
    backoffBaseMs <= 0 ||
    backoffMaxMs < backoffBaseMs
  ) {
    throw new Error("Codex wake backoff configuration is invalid");
  }
  const maxWakeAttemptsPerAsk = options.maxWakeAttemptsPerAsk ?? 3;
  if (
    !Number.isSafeInteger(maxWakeAttemptsPerAsk) ||
    maxWakeAttemptsPerAsk < 1 ||
    maxWakeAttemptsPerAsk > 10
  ) {
    throw new Error("Codex wake retry cap must be between 1 and 10");
  }
  const childTimeoutMs = options.childTimeoutMs ?? 5 * 60_000;
  const childKillGraceMs = options.childKillGraceMs ?? 5_000;
  const brokerDrainTimeoutMs = options.brokerDrainTimeoutMs ?? 1_000;
  if (
    !Number.isSafeInteger(childTimeoutMs) ||
    childTimeoutMs <= 0 ||
    childTimeoutMs > 60 * 60_000 ||
    !Number.isSafeInteger(childKillGraceMs) ||
    childKillGraceMs <= 0 ||
    childKillGraceMs > 30_000 ||
    !Number.isSafeInteger(brokerDrainTimeoutMs) ||
    brokerDrainTimeoutMs <= 0 ||
    brokerDrainTimeoutMs > 30_000
  ) {
    throw new Error("Codex wake child timeout configuration is invalid");
  }

  const now = options.now ?? Date.now;
  const logger = options.logger ?? ((message: string) => console.error(message));
  const platform = options.platform ?? process.platform;
  const credentialPaths = Object.freeze([...(options.credentialPaths ?? [])]);
  const spawnProcess =
    options.spawnProcess ??
    ((command, args, spawnOptions) =>
      defaultSpawnProcess(
        command,
        args,
        spawnOptions,
        platform,
        credentialPaths,
        childKillGraceMs,
      ));
  const wakeRecords = new Map<string, AskWakeRecord>();
  let current: CodexWakeSnapshot = Object.freeze({ state: "idle", askCount: 0 });
  let started = false;
  let stopped = false;
  let terminal = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let pollInFlight: Promise<void> | undefined;
  let childRun: ActiveWakeChild | undefined;
  let pollFailureCount = 0;
  let pollBackoffUntil = 0;
  let observationSequence = 0;

  const update = (state: CodexWakeState, askCount = current.askCount) => {
    const normalizedCount = Number.isSafeInteger(askCount) && askCount > 0 ? askCount : 0;
    if (current.state === state && current.askCount === normalizedCount) return;
    current = Object.freeze({ state, askCount: normalizedCount });
    logger(`knock-codex-listener state=${state} asks=${normalizedCount}`);
  };

  const clearTimer = () => {
    if (timer) clearTimeout(timer);
    timer = undefined;
  };

  const schedule = (delayMs: number) => {
    if (stopped || terminal) return;
    clearTimer();
    timer = setTimeout(() => {
      timer = undefined;
      void pollNow();
    }, Math.max(0, delayMs));
  };

  const exponentialDelay = (attempt: number) =>
    Math.min(backoffBaseMs * 2 ** Math.max(0, attempt - 1), backoffMaxMs);

  const nextPollBackoff = () => {
    pollFailureCount = Math.min(pollFailureCount + 1, 30);
    pollBackoffUntil = now() + exponentialDelay(pollFailureCount);
    update("backoff");
  };

  const finishChild = (run: ActiveWakeChild, succeeded: boolean) => {
    if (run.finished) return;
    run.finished = true;
    closeRunCapability(run);
    if (run.timeoutTimer) clearTimeout(run.timeoutTimer);
    run.timeoutTimer = undefined;
    if (run.killTimer) clearTimeout(run.killTimer);
    run.killTimer = undefined;
    if (childRun === run) childRun = undefined;
    if (stopped || terminal) return;

    const record = wakeRecords.get(run.identityKey);
    if (
      record &&
      !record.terminal &&
      !run.staleGeneration &&
      record.authorityGeneration === run.authorityGeneration
    ) {
      if (succeeded) {
        record.awaitingSettlementObservation = true;
        record.cooldownUntil = 0;
      } else {
        record.cooldownUntil = now() + exponentialDelay(record.attempts);
      }
    }
    update("backoff");
    schedule(0);
  };

  function terminateChild(run: ActiveWakeChild): void {
    if (run.finished || run.terminating) return;
    run.terminating = true;
    closeRunCapability(run);
    if (run.timeoutTimer) clearTimeout(run.timeoutTimer);
    run.timeoutTimer = undefined;
    const signalSupervisor = (signal: NodeJS.Signals) => {
      if (run.finished) return;
      try {
        run.process.kill(signal);
      } catch {
        // The stable child handle's exit/close observation remains authoritative.
      }
    };
    signalSupervisor("SIGTERM");
    run.killTimer = setTimeout(() => {
      if (run.finished) return;
      signalSupervisor("SIGKILL");
      run.killTimer = undefined;
    }, childKillGraceMs);
    unrefTimer(run.killTimer);
  }

  const terminateChildWhenDrained = (run: ActiveWakeChild) => {
    if (run.finished || run.terminating || run.drainTerminationPending) return;
    if (!run.wakeCapability.hasActiveResponse()) {
      terminateChild(run);
      return;
    }
    run.drainTerminationPending = true;
    const terminateAfterDrain = () => {
      run.drainTerminationPending = false;
      if (childRun === run && !run.finished && !run.terminating) {
        terminateChild(run);
      }
    };
    void run.wakeCapability
      .whenDrained(brokerDrainTimeoutMs)
      .then(terminateAfterDrain, terminateAfterDrain);
  };

  const fenceStaleGeneration = (run: ActiveWakeChild) => {
    if (run.staleGeneration) return;
    run.staleGeneration = true;
    run.wakeCapability.revoke();
    terminateChildWhenDrained(run);
  };

  function closeRunCapability(run: ActiveWakeChild): void {
    if (run.capabilityClosed) return;
    run.capabilityClosed = true;
    run.unsubscribeCapabilityTerminal?.();
    run.unsubscribeCapabilityTerminal = undefined;
    void run.wakeCapability.close().catch(() => undefined);
  }

  const fence = () => {
    if (terminal) return;
    terminal = true;
    clearTimer();
    wakeRecords.clear();
    if (childRun) {
      childRun.wakeCapability.revoke();
      terminateChildWhenDrained(childRun);
    }
    update("fenced", 0);
    options.onFatal?.();
  };

  const identityKeyFor = (ask: Pick<PendingWakeAsk, "askId" | "clientTurnId">) =>
    ask.askId;

  const pruneWakeRecords = (currentlyObserved: ReadonlySet<string>) => {
    if (wakeRecords.size <= MAX_TRACKED_WAKE_ASKS) return;
    const activeIdentity = childRun?.identityKey;
    const candidates = [...wakeRecords.entries()]
      .filter(([identityKey]) => identityKey !== activeIdentity)
      .sort((left, right) => {
        const leftRecord = left[1];
        const rightRecord = right[1];
        const leftPriority = leftRecord.terminal
          ? 0
          : leftRecord.awaitingSettlementObservation
            ? 1
            : currentlyObserved.has(left[0])
              ? 3
              : 2;
        const rightPriority = rightRecord.terminal
          ? 0
          : rightRecord.awaitingSettlementObservation
            ? 1
            : currentlyObserved.has(right[0])
              ? 3
              : 2;
        return leftPriority - rightPriority ||
          leftRecord.lastSeenSequence - rightRecord.lastSeenSequence;
      });
    for (const [identityKey] of candidates) {
      if (wakeRecords.size <= MAX_TRACKED_WAKE_ASKS) break;
      wakeRecords.delete(identityKey);
    }
  };

  const observePending = (observations: readonly PendingWakeAsk[]): PendingWakeAsk[] => {
    observationSequence += 1;
    const normalized = normalizedPollAsks(observations);
    const currentlyObserved = new Set<string>();
    const eligible: PendingWakeAsk[] = [];
    for (const ask of normalized) {
      const identityKey = identityKeyFor(ask);
      currentlyObserved.add(identityKey);
      const previous = wakeRecords.get(identityKey);
      if (!previous) {
        wakeRecords.set(identityKey, {
          askId: ask.askId,
          clientTurnId: ask.clientTurnId,
          revision: ask.revision,
          authorityGeneration: ask.authorityGeneration,
          attempts: 0,
          cooldownUntil: 0,
          awaitingSettlementObservation: false,
          unsettledSuccessfulExits: 0,
          terminal: ask.terminal === true,
          lastSeenSequence: observationSequence,
        });
      } else {
        const priorAuthorityGeneration = previous.authorityGeneration;
        const observedAuthorityGeneration = ask.authorityGeneration;
        const firstPositiveGenerationAdvances =
          priorAuthorityGeneration === undefined &&
          observedAuthorityGeneration !== undefined &&
          (previous.attempts >= maxWakeAttemptsPerAsk ||
            previous.awaitingSettlementObservation ||
            previous.unsettledSuccessfulExits > 0);
        const authorityAdvanced =
          observedAuthorityGeneration !== undefined &&
          ((priorAuthorityGeneration !== undefined &&
            observedAuthorityGeneration > priorAuthorityGeneration) ||
            firstPositiveGenerationAdvances);
        const activeRun =
          childRun?.identityKey === identityKey ? childRun : undefined;
        previous.clientTurnId = ask.clientTurnId;
        previous.revision = ask.revision;
        if (
          observedAuthorityGeneration !== undefined &&
          (priorAuthorityGeneration === undefined ||
            observedAuthorityGeneration > priorAuthorityGeneration)
        ) {
          previous.authorityGeneration = observedAuthorityGeneration;
        }
        previous.terminal = previous.terminal || ask.terminal === true;
        if (previous.terminal) {
          previous.awaitingSettlementObservation = false;
        } else if (authorityAdvanced) {
          previous.attempts = 0;
          previous.cooldownUntil = 0;
          previous.awaitingSettlementObservation = false;
          previous.unsettledSuccessfulExits = 0;
          if (
            activeRun &&
            activeRun.authorityGeneration !== observedAuthorityGeneration
          ) {
            fenceStaleGeneration(activeRun);
          }
        } else if (
          priorAuthorityGeneration === undefined &&
          observedAuthorityGeneration !== undefined &&
          activeRun?.authorityGeneration === undefined
        ) {
          activeRun.authorityGeneration = observedAuthorityGeneration;
        } else if (previous.awaitingSettlementObservation) {
          previous.awaitingSettlementObservation = false;
          previous.unsettledSuccessfulExits = Math.min(
            previous.unsettledSuccessfulExits + 1,
            30,
          );
          previous.cooldownUntil =
            now() + exponentialDelay(previous.unsettledSuccessfulExits);
        }
        previous.lastSeenSequence = observationSequence;
      }
      const record = wakeRecords.get(identityKey);
      if (
        record &&
        !record.terminal &&
        !ask.legacyDrain &&
        ask.wakeable !== false
      ) {
        eligible.push(ask);
      }
    }
    for (const [identityKey, record] of wakeRecords) {
      if (
        record.awaitingSettlementObservation &&
        identityKey !== childRun?.identityKey &&
        !currentlyObserved.has(identityKey)
      ) {
        record.awaitingSettlementObservation = false;
        record.terminal = true;
      }
    }
    pruneWakeRecords(currentlyObserved);
    return eligible;
  };

  const wake = async (ask: PendingWakeAsk, record: AskWakeRecord) => {
    if (childRun || stopped || terminal) return;
    record.attempts += 1;
    update("waking");
    let wakeCapability: WakeCapabilityHandle | undefined;
    let childEnv: NodeJS.ProcessEnv;
    try {
      if (!options.openWakeCapability) throw new Error("wake capability unavailable");
      wakeCapability = await options.openWakeCapability(ask);
      if (stopped || terminal) {
        await wakeCapability.close();
        return;
      }
      childEnv = buildCodexWakeEnvironment(
        chatId,
        options.parentEnv ?? process.env,
        wakeCapability,
      );
    } catch (error: unknown) {
      const reason = error instanceof Error ? error.message : "invalid child environment";
      logger(`knock-codex-listener child authority unavailable: ${reason}`);
      fence();
      return;
    }
    let childProcess: WakeChild;
    try {
      const spawnEnvironment = scrubCodexWakeEnvironment({ ...childEnv });
      childProcess = spawnProcess(
        "codex",
        ["exec", "resume", "--all", chatId, CODEX_WAKE_PROMPT],
        {
          stdio: "ignore",
          env: spawnEnvironment,
          detached: platform !== "win32",
        },
      );
    } catch {
      if (wakeCapability) void wakeCapability.close().catch(() => undefined);
      record.cooldownUntil = now() + exponentialDelay(record.attempts);
      update("backoff");
      return;
    }

    let run: ActiveWakeChild;
    run = {
      process: childProcess,
      identityKey: identityKeyFor(ask),
      authorityGeneration: ask.authorityGeneration,
      staleGeneration: false,
      finished: false,
      terminating: false,
      drainTerminationPending: false,
      wakeCapability,
      capabilityClosed: false,
      finish: (succeeded) => finishChild(run, succeeded),
    };
    childRun = run;
    run.unsubscribeCapabilityTerminal = wakeCapability.onTerminal((event) => {
      if (childRun !== run || run.finished) return;
      if (run.staleGeneration) {
        terminateChildWhenDrained(run);
        return;
      }
      if (event.reason === "settled") {
        const record = wakeRecords.get(run.identityKey);
        if (record) {
          record.terminal = true;
          record.awaitingSettlementObservation = false;
        }
        return;
      }
      if (event.reason === "external") {
        terminateChildWhenDrained(run);
        return;
      }
      fence();
    });
    run.timeoutTimer = setTimeout(() => {
      if (run.finished) return;
      logger("knock-codex-listener child timeout; terminating");
      fence();
    }, childTimeoutMs);
    unrefTimer(run.timeoutTimer);

    childProcess.once("spawn", () => {
      if (!stopped && !terminal && childRun === run) update("working");
    });
    childProcess.once("error", () => run.finish(false));
    childProcess.once("exit", (code, signal) => run.finish(code === 0 && signal === null));
    childProcess.once("close", (code, signal) => run.finish(code === 0 && signal === null));
  };

  const runPoll = async () => {
    if (stopped || terminal) return;
    if (now() < pollBackoffUntil) {
      update("backoff");
      return;
    }
    try {
      const observations = await options.pollPending();
      if (stopped || terminal) return;
      pollFailureCount = 0;
      pollBackoffUntil = 0;
      const eligible = observePending(observations);
      const askCount = eligible.length;
      if (childRun) {
        const activeRecord = wakeRecords.get(childRun.identityKey);
        if (activeRecord?.terminal) {
          childRun.wakeCapability.settleExternally();
          terminateChildWhenDrained(childRun);
        }
        update("working", askCount);
        return;
      }

      const candidate = eligible.find((ask) => {
        const record = wakeRecords.get(identityKeyFor(ask));
        return Boolean(
          record &&
            !record.terminal &&
            record.attempts < maxWakeAttemptsPerAsk &&
            !record.awaitingSettlementObservation &&
            now() >= record.cooldownUntil,
        );
      });
      if (candidate) {
        const record = wakeRecords.get(identityKeyFor(candidate));
        if (record) await wake(candidate, record);
        return;
      }

      const coolingDown = eligible.some((ask) => {
        const record = wakeRecords.get(identityKeyFor(ask));
        return Boolean(
            record &&
            record.attempts < maxWakeAttemptsPerAsk &&
            !record.awaitingSettlementObservation &&
            now() < record.cooldownUntil,
        );
      });
      const exhausted = eligible.some((ask) => {
        const record = wakeRecords.get(identityKeyFor(ask));
        return Boolean(record && record.attempts >= maxWakeAttemptsPerAsk);
      });
      update(exhausted ? "exhausted" : coolingDown ? "backoff" : "idle", askCount);
    } catch (error: unknown) {
      if (stopped || terminal) return;
      if (isWakeLeaseFencedError(error)) {
        fence();
        return;
      }
      nextPollBackoff();
    }
  };

  const pollNow = (): Promise<void> => {
    if (stopped || terminal) return Promise.resolve();
    if (pollInFlight) return pollInFlight;
    pollInFlight = runPoll().finally(() => {
      pollInFlight = undefined;
      if (stopped || terminal || timer) return;
      const remainingBackoff = Math.max(0, pollBackoffUntil - now());
      schedule(remainingBackoff > 0 ? remainingBackoff : pollIntervalMs);
    });
    return pollInFlight;
  };

  return {
    start() {
      if (started || stopped || terminal) return;
      started = true;
      schedule(0);
    },
    stop() {
      if (stopped) return;
      stopped = true;
      clearTimer();
      wakeRecords.clear();
      if (childRun) {
        terminal = true;
        update("fenced", 0);
        childRun.wakeCapability.revoke();
        terminateChildWhenDrained(childRun);
      } else if (!terminal) {
        update("idle", 0);
      }
    },
    pollNow,
    revoke: fence,
    snapshot: () => current,
  };
}
