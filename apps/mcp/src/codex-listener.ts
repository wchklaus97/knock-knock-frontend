#!/usr/bin/env node

import {
  agentCredentialIsolationPaths,
  createParentAgentApiClient,
} from "./client.js";
import { readAgentAsks } from "./ask-transport.js";
import {
  createCodexWakeRunner,
  pendingWakeAsksFromResponse,
  resolveCodexWakeChatId,
} from "./codex-wake-runner.js";
import { createWakeCapabilityBroker } from "./wake-capability-broker.js";
import { assertMacOSWakeSandboxAvailable } from "./macos-wake-sandbox.js";
import {
  listeningHeartbeatPath,
  listeningRegistrationPath,
  onListenerAuthorityRevoked,
  releaseListeningLease,
  requireActiveLeaseV2Authority,
  startListeningHeartbeat,
} from "./listening.js";
import {
  listenerRegistrationBody,
  listenerRenewalBody,
  listenerTakeoverRequested,
} from "./thread-binding.js";

function pollIntervalMs(): number {
  const raw = process.env.KNOCK_KNOCK_WAKE_POLL_MS?.trim();
  if (!raw) return 3_000;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 2_000 || value > 5_000) {
    throw new Error("KNOCK_KNOCK_WAKE_POLL_MS must be between 2000 and 5000");
  }
  return value;
}

async function main(): Promise<void> {
  const chatId = resolveCodexWakeChatId();
  const credentialPaths = assertMacOSWakeSandboxAvailable(
    agentCredentialIsolationPaths(),
  );
  const parentApi = createParentAgentApiClient();
  const configuredPollIntervalMs = pollIntervalMs();
  const heartbeat = startListeningHeartbeat(
    {
      acquire: (takeover) =>
        parentApi(listeningRegistrationPath(), {
          method: "POST",
          json: listenerRegistrationBody(takeover),
          timeoutMs: 5_000,
        }),
      renew: (lease) =>
        parentApi(listeningHeartbeatPath(), {
          method: "POST",
          json: listenerRenewalBody(lease),
          timeoutMs: 5_000,
        }),
      release: (lease) =>
        releaseListeningLease(
          (path, init) =>
            parentApi(path, {
              ...init,
              timeoutMs: 5_000,
            }),
          lease,
        ),
    },
    { takeover: listenerTakeoverRequested() },
  );

  let runner: ReturnType<typeof createCodexWakeRunner> | undefined;
  let unsubscribeRevocation = () => undefined;
  let stopPromise: Promise<void> | undefined;
  const stop = (): Promise<void> => {
    if (stopPromise) return stopPromise;
    let resolveStop: () => void = () => undefined;
    stopPromise = new Promise<void>((resolve) => {
      resolveStop = resolve;
    });
    unsubscribeRevocation();
    process.off("SIGINT", stopFromSignal);
    process.off("SIGTERM", stopFromSignal);
    runner?.stop();
    void heartbeat.stop().then(resolveStop, resolveStop);
    return stopPromise;
  };
  const stopFromSignal = () => {
    void stop();
  };

  try {
    runner = createCodexWakeRunner({
      chatId,
      credentialPaths,
      pollIntervalMs: configuredPollIntervalMs,
      onFatal: () => {
        void stop();
      },
      openWakeCapability: async (ask) => {
        if (!ask.sessionId) throw new Error("wake Ask is missing its session identity");
        requireActiveLeaseV2Authority(heartbeat.status());
        return createWakeCapabilityBroker({
          askId: ask.askId,
          sessionId: ask.sessionId,
          backendRequest: (path, init) => parentApi(path, init),
          requireAuthority: () => requireActiveLeaseV2Authority(heartbeat.status()),
        });
      },
      pollPending: async () => {
        const beforePoll = heartbeat.status();
        if (beforePoll.protocol === "legacy") return [];
        requireActiveLeaseV2Authority(beforePoll);
        const response = await readAgentAsks<{ asks?: unknown[] }>(
          (path, init) => parentApi(path, init),
          { timeoutMs: 5_000 },
        );
        requireActiveLeaseV2Authority(heartbeat.status());
        return pendingWakeAsksFromResponse(response);
      },
    });
  } catch (error: unknown) {
    await stop();
    throw error;
  }
  unsubscribeRevocation = onListenerAuthorityRevoked(() => {
    runner?.revoke();
    void stop();
  });
  process.once("SIGINT", stopFromSignal);
  process.once("SIGTERM", stopFromSignal);
  runner.start();
}

main().catch(() => {
  console.error(
    "knock-codex-listener failed to start: valid CODEX_THREAD_ID or KNOCK_KNOCK_CHAT_ID and staging credentials are required",
  );
  process.exitCode = 1;
});
