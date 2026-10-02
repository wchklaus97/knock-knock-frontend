export type AgentAskReadOptions = Readonly<{
  waitMs?: number;
  timeoutMs?: number;
}>;

export type AgentAskClaimOptions = Readonly<{
  timeoutMs?: number;
}>;

export type AgentAskRequest = (
  path: string,
  init: RequestInit & { json?: unknown; timeoutMs?: number },
) => Promise<unknown>;

export type AskClaimQueue = <T>(operation: () => Promise<T>) => Promise<T>;

export function createAskClaimQueue(): AskClaimQueue {
  let tail: Promise<void> = Promise.resolve();
  return <T>(operation: () => Promise<T>): Promise<T> => {
    const result = tail.then(operation, operation);
    tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  };
}

/**
 * Strictly read-only Ask observation. This route must never carry a claim
 * query or request body.
 */
export async function readAgentAsks<T = unknown>(
  request: AgentAskRequest,
  options: AgentAskReadOptions = {},
): Promise<T> {
  const query = new URLSearchParams();
  if (options.waitMs !== undefined) query.set("wait_ms", String(options.waitMs));
  const suffix = query.size > 0 ? `?${query}` : "";
  return (await request(`/v1/agents/me/asks${suffix}`, {
    method: "GET",
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
  })) as T;
}

/**
 * The only modern Ask-claim mutation. Claim credentials in the response must
 * remain inside MCP claim state or pass through diagnostic redaction.
 */
export async function claimAgentAsks<T = unknown>(
  request: AgentAskRequest,
  options: AgentAskClaimOptions = {},
): Promise<T> {
  return (await request("/v1/agents/me/asks/claim", {
    method: "POST",
    ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
  })) as T;
}
