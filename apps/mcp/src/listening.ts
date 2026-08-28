/** Keep Staging/local last_seen_at fresh so the phone Ask dock can listen. */

import { resetAskClaimState } from "./ask-claims.js";
import { safeErrorMessage } from "./redaction.js";
import {
  currentListenerLeaseFence,
  setListenerLeaseFence,
  type ListenerLeaseFence,
} from "./thread-binding.js";

export const LISTENING_LEASE_MS = 90_000;
export const LISTENING_RENEW_AFTER_MS = 30_000;
export const LISTENING_HEARTBEAT_MS = LISTENING_RENEW_AFTER_MS;
export const LISTENING_RELEASE_ATTEMPT_TIMEOUT_MS = 5_250;

export type ListenerLease = ListenerLeaseFence;
export type ListeningProtocol = "negotiating" | "legacy" | "lease-v2";

export type ListeningStatus = Readonly<{
  registered: boolean;
  consumerActive: boolean;
  fenced: boolean;
  protocol: ListeningProtocol;
  generation?: number;
  renewAfterMs?: number;
  lastError?: string;
}>;

export type ListeningTransport = {
  acquire: (takeover: boolean) => Promise<unknown>;
  renew: (lease: ListenerLease) => Promise<unknown>;
  release?: (lease: ListenerLease) => Promise<unknown>;
};

export type ListeningHeartbeatHandle = {
  stop: () => Promise<void>;
  status: () => ListeningStatus;
  setConsumerActive: (active: boolean) => void;
};

export type ListeningHeartbeatOptions = {
  takeover?: boolean;
  intervalMs?: number;
  inheritedFence?: ListenerLease;
  inheritedFenceOwned?: boolean;
  shutdownAcquireTimeoutMs?: number;
  releaseAttemptTimeoutMs?: number;
  onStatusChange?: (status: ListeningStatus) => void;
};

type InFlightListenerAcquire = {
  readonly epoch: number;
  readonly promise: Promise<ListenerLease | null>;
  invalidated: boolean;
};

export type ListeningShutdownEventSource = {
  once: (event: string, listener: () => void) => unknown;
  off: (event: string, listener: () => void) => unknown;
};

export type ListeningShutdownBinding = Readonly<{
  source: ListeningShutdownEventSource;
  event: string;
  reason: string;
}>;

export type ListeningShutdownController = {
  stop: (reason?: string) => Promise<void>;
  wait: () => Promise<void>;
  dispose: () => void;
};

export function createListeningShutdownController(
  heartbeat: ListeningHeartbeatHandle,
  options: {
    bindings?: readonly ListeningShutdownBinding[];
    afterStop?: (reason: string) => void | Promise<void>;
    onError?: (error: unknown) => void;
  } = {},
): ListeningShutdownController {
  const registrations: Array<{
    source: ListeningShutdownEventSource;
    event: string;
    listener: () => void;
  }> = [];
  let stopPromise: Promise<void> | undefined;
  let resolveWait: () => void = () => undefined;
  const stopped = new Promise<void>((resolve) => {
    resolveWait = resolve;
  });

  const dispose = () => {
    for (const registration of registrations.splice(0)) {
      registration.source.off(registration.event, registration.listener);
    }
  };

  const stop = (reason = "listener_stopped"): Promise<void> => {
    if (stopPromise) return stopPromise;
    let resolveStop: () => void = () => undefined;
    stopPromise = new Promise<void>((resolve) => {
      resolveStop = resolve;
    });
    dispose();
    void (async () => {
      try {
        await heartbeat.stop();
      } catch (error: unknown) {
        options.onError?.(error);
      }
      try {
        await options.afterStop?.(reason);
      } catch (error: unknown) {
        options.onError?.(error);
      } finally {
        resolveStop();
        resolveWait();
      }
    })();
    return stopPromise;
  };

  for (const binding of options.bindings ?? []) {
    if (
      registrations.some(
        (registration) =>
          registration.source === binding.source && registration.event === binding.event,
      )
    ) {
      continue;
    }
    const listener = () => {
      void stop(binding.reason);
    };
    registrations.push({ source: binding.source, event: binding.event, listener });
    binding.source.once(binding.event, listener);
  }

  return { stop, wait: () => stopped, dispose };
}

type ListenerAuthorityRevocationHandler = (reason: string) => void;

const authorityRevocationHandlers = new Set<ListenerAuthorityRevocationHandler>();
let listenerAuthorityRevokedState = false;
let nextListeningHeartbeatOwner = 0;
let activeListeningHeartbeatOwner: number | undefined;

export function onListenerAuthorityRevoked(
  handler: ListenerAuthorityRevocationHandler,
): () => void {
  authorityRevocationHandlers.add(handler);
  return () => authorityRevocationHandlers.delete(handler);
}

export function listenerAuthorityIsRevoked(): boolean {
  return listenerAuthorityRevokedState;
}

export function listeningRegistrationPath(): string {
  return "/v1/agents/me/listener";
}

export function listeningReleasePath(): string {
  return listeningRegistrationPath();
}

export function listenerReleaseHeaders(
  lease: ListenerLease,
): Readonly<Record<string, string>> {
  return Object.freeze({
    "x-knock-listener-lease-id": lease.leaseId,
    "x-knock-listener-generation": String(lease.generation),
  });
}

export async function releaseListeningLease(
  request: (path: string, init: RequestInit) => Promise<unknown>,
  lease: ListenerLease,
): Promise<unknown> {
  return request(listeningReleasePath(), {
    method: "DELETE",
    headers: listenerReleaseHeaders(lease),
  });
}

export function listeningHeartbeatPath(): string {
  return "/v1/agents/me/listener/heartbeat";
}

export function isInvalidAgentKeyError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\b401\b/.test(message) || /invalid agent key/i.test(message);
}

export function isLeaseFencedError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\blease_fenced\b/i.test(message);
}

export function safeListeningErrorMessage(error: unknown): string {
  return safeErrorMessage(error);
}

export const STAGING_PAIRING_HINT =
  "This Mac is not paired to Staging. On the iPhone open Settings → Connect an Agent → Generate pairing code, then run vab pair against https://knock-knock-backend-staging.wch-klaus.workers.dev --write-env .env.agent.staging and restart MCP.";

export function agentAuthFailureMessage(error: unknown): string | null {
  if (!isInvalidAgentKeyError(error)) return null;
  return STAGING_PAIRING_HINT;
}

function parseListenerLease(response: unknown): ListenerLease | null {
  if (!response || typeof response !== "object" || Array.isArray(response)) return null;
  const value = response as Record<string, unknown>;
  const leaseFields = ["lease_id", "generation", "renew_after_ms"];
  if (!leaseFields.some((field) => Object.prototype.hasOwnProperty.call(value, field))) {
    return null;
  }

  const leaseId = value.lease_id;
  const generation = value.generation;
  const renewAfterMs = value.renew_after_ms;
  if (
    typeof leaseId !== "string" ||
    leaseId.length < 8 ||
    typeof generation !== "number" ||
    !Number.isSafeInteger(generation) ||
    generation <= 0 ||
    typeof renewAfterMs !== "number" ||
    !Number.isSafeInteger(renewAfterMs) ||
    renewAfterMs <= 0
  ) {
    throw new Error("Invalid lease-v2 listener response");
  }
  return { leaseId, generation, renewAfterMs };
}

function clearLocalListenerAuthority(): void {
  setListenerLeaseFence(null);
  resetAskClaimState();
}

export function revokeListenerAuthority(reason = "listener_authority_revoked"): void {
  activeListeningHeartbeatOwner = undefined;
  clearLocalListenerAuthority();
  if (listenerAuthorityRevokedState) return;
  listenerAuthorityRevokedState = true;
  for (const handler of [...authorityRevocationHandlers]) handler(reason);
}

export function revokeListenerAuthorityForApiResponse(
  status: number,
  responseBody: string,
): boolean {
  if (status < 400) return false;
  const reason = /invalid agent key|invalid_agent_key|unauthorized/i.test(responseBody)
    ? "invalid_agent_key"
    : /lease_fenced|listener_fenced/i.test(responseBody)
      ? "lease_fenced"
      : /listener_(?:lease_)?(?:expired|required|missing|invalid|inactive|not_active)|lease_expired|listener_generation_mismatch|lease_generation_mismatch/i.test(
            responseBody,
          )
        ? "listener_authority_lost"
        : undefined;
  if (!reason && status !== 401) return false;
  revokeListenerAuthority(reason ?? "invalid_agent_key");
  return true;
}

function activateLocalListenerAuthority(lease: ListenerLease): void {
  const previous = currentListenerLeaseFence();
  if (
    !previous ||
    previous.leaseId !== lease.leaseId ||
    previous.generation !== lease.generation
  ) {
    resetAskClaimState();
  }
  listenerAuthorityRevokedState = false;
  setListenerLeaseFence(lease);
}

export function negotiateListenerLease(response: unknown): ListenerLease | null {
  const lease = parseListenerLease(response);
  if (lease) activateLocalListenerAuthority(lease);
  else clearLocalListenerAuthority();
  return lease;
}

export function hasActiveLeaseV2Authority(
  status: ListeningStatus | undefined,
): boolean {
  const activeLease = currentListenerLeaseFence();
  return Boolean(
    status &&
      status.registered &&
      !status.fenced &&
      status.protocol === "lease-v2" &&
      !listenerAuthorityRevokedState &&
      activeLease &&
      status.generation === activeLease.generation,
  );
}

export function requireActiveLeaseV2Authority(
  status: ListeningStatus | undefined,
): void {
  if (hasActiveLeaseV2Authority(status)) return;
  if (listenerAuthorityRevokedState) {
    throw new Error("listener_authority_revoked");
  }
  if (status?.fenced) throw new Error("lease_fenced");
  if (status?.protocol === "legacy") throw new Error("legacy_listener_drain_only");
  throw new Error("listener_lease_v2_authority_required");
}

export function requireLeaseV2ForAskWrite(
  status: ListeningStatus | undefined,
  askBearing: boolean,
): void {
  if (askBearing) requireActiveLeaseV2Authority(status);
}

export function listenerRenewalDelayMs(renewAfterMs?: number): number {
  if (
    renewAfterMs !== undefined &&
    Number.isSafeInteger(renewAfterMs) &&
    renewAfterMs >= 5_000 &&
    renewAfterMs < LISTENING_LEASE_MS
  ) {
    return renewAfterMs;
  }
  return LISTENING_RENEW_AFTER_MS;
}

export function startListeningHeartbeat(
  transport: ListeningTransport,
  options: ListeningHeartbeatOptions = {},
): ListeningHeartbeatHandle {
  if (
    options.intervalMs !== undefined &&
    (!Number.isFinite(options.intervalMs) || options.intervalMs <= 0)
  ) {
    throw new Error("Listening heartbeat interval must be positive");
  }
  if (options.inheritedFenceOwned === true && !options.inheritedFence) {
    throw new Error("Owned inherited listener fence is missing");
  }
  const releaseAttemptTimeoutMs =
    options.releaseAttemptTimeoutMs ?? LISTENING_RELEASE_ATTEMPT_TIMEOUT_MS;
  const shutdownAcquireTimeoutMs =
    options.shutdownAcquireTimeoutMs ?? LISTENING_RELEASE_ATTEMPT_TIMEOUT_MS;
  if (
    !Number.isSafeInteger(releaseAttemptTimeoutMs) ||
    releaseAttemptTimeoutMs <= 0 ||
    releaseAttemptTimeoutMs > 30_000 ||
    !Number.isSafeInteger(shutdownAcquireTimeoutMs) ||
    shutdownAcquireTimeoutMs <= 0 ||
    shutdownAcquireTimeoutMs > 30_000
  ) {
    throw new Error("Listener shutdown timeout is invalid");
  }

  const heartbeatOwner = ++nextListeningHeartbeatOwner;
  activeListeningHeartbeatOwner = heartbeatOwner;
  listenerAuthorityRevokedState = false;
  clearLocalListenerAuthority();
  const inheritedFence = options.inheritedFence
    ? Object.freeze({ ...options.inheritedFence })
    : undefined;
  if (inheritedFence) activateLocalListenerAuthority(inheritedFence);
  let stopped = false;
  let running = false;
  let takeoverConsumed = false;
  let lease: ListenerLease | null = inheritedFence ?? null;
  let ownsLease = inheritedFence ? options.inheritedFenceOwned === true : false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let acquireEpoch = 0;
  let inFlightAcquire: InFlightListenerAcquire | undefined;
  let currentStatus: ListeningStatus = Object.freeze(
    inheritedFence
      ? {
          registered: true,
          consumerActive: false,
          fenced: false,
          protocol: "lease-v2",
          generation: inheritedFence.generation,
          renewAfterMs: inheritedFence.renewAfterMs,
        }
      : {
          registered: false,
          consumerActive: false,
          fenced: false,
          protocol: "negotiating",
        },
  );

  const updateStatus = (patch: Partial<ListeningStatus>) => {
    currentStatus = Object.freeze({ ...currentStatus, ...patch });
    options.onStatusChange?.(currentStatus);
  };

  let unsubscribeRevocation = () => undefined;

  const stopWith = (
    patch: Partial<ListeningStatus>,
    reason: string,
  ) => {
    stopped = true;
    if (timer) clearTimeout(timer);
    timer = undefined;
    unsubscribeRevocation();
    if (activeListeningHeartbeatOwner === heartbeatOwner) {
      activeListeningHeartbeatOwner = undefined;
      revokeListenerAuthority(reason);
    }
    lease = null;
    ownsLease = false;
    updateStatus({
      registered: false,
      consumerActive: false,
      generation: undefined,
      renewAfterMs: undefined,
      ...patch,
    });
  };

  unsubscribeRevocation = onListenerAuthorityRevoked((reason) => {
    if (stopped) return;
    stopped = true;
    if (timer) clearTimeout(timer);
    timer = undefined;
    lease = null;
    ownsLease = false;
    updateStatus({
      registered: false,
      consumerActive: false,
      fenced: true,
      generation: undefined,
      renewAfterMs: undefined,
      lastError: reason,
    });
  });

  const schedule = () => {
    if (stopped || activeListeningHeartbeatOwner !== heartbeatOwner) return;
    if (inheritedFence && currentStatus.protocol === "lease-v2") return;
    const delay = options.intervalMs ?? listenerRenewalDelayMs(lease?.renewAfterMs);
    timer = setTimeout(() => {
      timer = undefined;
      void run();
    }, delay);
  };

  const run = async (): Promise<void> => {
    if (
      stopped ||
      running ||
      activeListeningHeartbeatOwner !== heartbeatOwner
    ) {
      return;
    }
    running = true;
    try {
      if (currentStatus.protocol === "lease-v2") {
        if (!lease) throw new Error("Lease-v2 listener is missing its fence");
        const response = await transport.renew({ ...lease });
        if (stopped || activeListeningHeartbeatOwner !== heartbeatOwner) return;
        const renewed = parseListenerLease(response);
        if (!renewed) throw new Error("Invalid lease-v2 heartbeat response");
        lease = renewed;
        activateLocalListenerAuthority(renewed);
        updateStatus({
          registered: true,
          fenced: false,
          protocol: "lease-v2",
          generation: renewed.generation,
          renewAfterMs: renewed.renewAfterMs,
          lastError: undefined,
        });
      } else {
        const takeover = !inheritedFence && !takeoverConsumed && options.takeover === true;
        const epoch = ++acquireEpoch;
        let acquireAttempt!: InFlightListenerAcquire;
        const acquirePromise = Promise.resolve()
          .then(() => transport.acquire(takeover))
          .then((response) => {
            const acquired = parseListenerLease(response);
            return acquired ? Object.freeze({ ...acquired }) : null;
          });
        acquireAttempt = {
          epoch,
          promise: acquirePromise,
          invalidated: false,
        };
        inFlightAcquire = acquireAttempt;
        let acquired: ListenerLease | null;
        try {
          acquired = await acquirePromise;
        } finally {
          if (inFlightAcquire === acquireAttempt) inFlightAcquire = undefined;
        }
        if (
          acquireAttempt.invalidated ||
          acquireAttempt.epoch !== acquireEpoch ||
          stopped ||
          activeListeningHeartbeatOwner !== heartbeatOwner
        ) {
          return;
        }
        takeoverConsumed = true;
        lease = acquired;
        if (acquired) {
          ownsLease = true;
          activateLocalListenerAuthority(acquired);
          updateStatus({
            registered: true,
            consumerActive: false,
            fenced: false,
            protocol: "lease-v2",
            generation: acquired.generation,
            renewAfterMs: acquired.renewAfterMs,
            lastError: undefined,
          });
        } else {
          clearLocalListenerAuthority();
          updateStatus({
            registered: false,
            consumerActive: false,
            fenced: false,
            protocol: "legacy",
            generation: undefined,
            renewAfterMs: LISTENING_RENEW_AFTER_MS,
            lastError: "legacy_listener_drain_only",
          });
        }
      }
    } catch (error: unknown) {
      if (stopped) return;
      if (isLeaseFencedError(error)) {
        stopWith({ fenced: true, lastError: "lease_fenced" }, "lease_fenced");
        console.error("knock-knock listening heartbeat stopped: listener lease fenced");
        return;
      }
      if (isInvalidAgentKeyError(error)) {
        stopWith(
          { fenced: false, lastError: "invalid_agent_key" },
          "invalid_agent_key",
        );
        console.error(
          "knock-knock listening heartbeat stopped: pair this host to Staging, then restart MCP",
        );
        return;
      }
      clearLocalListenerAuthority();
      const message = safeListeningErrorMessage(error);
      updateStatus({
        registered: false,
        consumerActive: false,
        generation: undefined,
        lastError: message,
      });
      console.error(`knock-knock listening heartbeat failed: ${message}`);
    } finally {
      running = false;
      schedule();
    }
  };

  const isTransientReleaseError = (error: unknown): boolean => {
    if (isInvalidAgentKeyError(error) || isLeaseFencedError(error)) return false;
    const message = error instanceof Error ? error.message : String(error);
    return (
      /\b(?:408|425|429|5\d\d)\b/.test(message) ||
      /(?:network|fetch failed|timed? ?out|econnreset|econnrefused|enotfound|eai_again)/i.test(
        message,
      )
    );
  };

  const releaseForStop = async (releaseLease: ListenerLease): Promise<void> => {
    if (!transport.release) return;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        let timeout: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([
            Promise.resolve().then(() => transport.release?.(releaseLease)),
            new Promise<never>((_resolve, reject) => {
              timeout = setTimeout(
                () => reject(new Error("listener release timed out")),
                releaseAttemptTimeoutMs,
              );
            }),
          ]);
        } finally {
          if (timeout) clearTimeout(timeout);
        }
        return;
      } catch (error: unknown) {
        if (isLeaseFencedError(error)) return;
        if (attempt === 0 && isTransientReleaseError(error)) continue;
        console.error(
          `knock-knock listener release failed: ${safeListeningErrorMessage(error)}`,
        );
        return;
      }
    }
  };

  const acquireLeaseForStop = async (
    acquireAttempt: InFlightListenerAcquire,
  ): Promise<ListenerLease | null> => {
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let timedOut = false;
    try {
      return await Promise.race([
        acquireAttempt.promise,
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(() => {
            timedOut = true;
            reject(new Error("listener acquire shutdown timed out"));
          }, shutdownAcquireTimeoutMs);
        }),
      ]);
    } catch {
      if (timedOut) acquireAttempt.invalidated = true;
      return null;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  };

  let stopPromise: Promise<void> | undefined;
  const stop = (): Promise<void> => {
    if (stopPromise) return stopPromise;

    let resolveStop: () => void = () => undefined;
    stopPromise = new Promise<void>((resolve) => {
      resolveStop = resolve;
    });
    stopped = true;
    if (timer) clearTimeout(timer);
    timer = undefined;
    unsubscribeRevocation();
    const acquireAtStop = inFlightAcquire;
    const mayReleaseAcquiredLease =
      activeListeningHeartbeatOwner === heartbeatOwner && !currentStatus.fenced;
    let releaseLease =
      activeListeningHeartbeatOwner === heartbeatOwner &&
      currentStatus.protocol === "lease-v2" &&
      !currentStatus.fenced &&
      ownsLease &&
      lease
        ? Object.freeze({ ...lease })
        : undefined;

    void (async () => {
      try {
        if (!releaseLease && mayReleaseAcquiredLease && acquireAtStop) {
          const acquired = await acquireLeaseForStop(acquireAtStop);
          if (acquired && !acquireAtStop.invalidated) {
            releaseLease = Object.freeze({ ...acquired });
          }
        }
        if (releaseLease && transport.release) {
          await releaseForStop(releaseLease);
        }
      } finally {
        stopWith(
          { fenced: false, lastError: undefined },
          "listener_stopped",
        );
        resolveStop();
      }
    })();
    return stopPromise;
  };

  if (!inheritedFence) void run();
  return {
    stop,
    status: () => currentStatus,
    setConsumerActive(active) {
      const allowed = active && hasActiveLeaseV2Authority(currentStatus);
      updateStatus({ consumerActive: allowed });
    },
  };
}
