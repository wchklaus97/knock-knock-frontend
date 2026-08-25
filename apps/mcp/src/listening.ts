/** Keep Staging/local last_seen_at fresh so the phone Ask dock can listen. */

export const LISTENING_HEARTBEAT_MS = 20_000;

export function listeningRegistrationPath(): string {
  return "/v1/agents/me/listener";
}

export function isInvalidAgentKeyError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /\b401\b/.test(message) || /invalid agent key/i.test(message);
}

export const STAGING_PAIRING_HINT =
  "This Mac is not paired to Staging. On the iPhone open Settings → Connect an Agent → Generate pairing code, then run vab pair against https://knock-knock-backend-staging.wch-klaus.workers.dev --write-env .env.agent.staging and restart MCP.";

export function agentAuthFailureMessage(error: unknown): string | null {
  if (!isInvalidAgentKeyError(error)) return null;
  return STAGING_PAIRING_HINT;
}

export function startListeningHeartbeat(
  tick: () => Promise<void>,
  intervalMs: number = LISTENING_HEARTBEAT_MS,
): { stop: () => void } {
  let stopped = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  const run = () => {
    void tick().catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      if (isInvalidAgentKeyError(error)) {
        stopped = true;
        if (timer) clearInterval(timer);
        console.error(
          "knock-knock listening heartbeat stopped: pair this host to Staging, then restart MCP",
        );
        return;
      }
      console.error(`knock-knock listening heartbeat failed: ${message}`);
    });
  };
  run();
  timer = setInterval(() => {
    if (!stopped) run();
  }, intervalMs);
  return {
    stop() {
      stopped = true;
      if (timer) clearInterval(timer);
    },
  };
}
