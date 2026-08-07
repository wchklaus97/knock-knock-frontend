import type { Context, Next } from "hono";
import { config } from "./config.js";
import { recordError } from "./observability.js";

type Bucket = { count: number; resetAt: number };
const buckets = new Map<string, Bucket>();

function clientAddress(c: Context): string {
  if (config.trustProxy) {
    return c.req.header("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  }
  return c.req.header("x-real-ip") ?? c.req.header("user-agent") ?? "unknown";
}

function isAuthPath(path: string): boolean {
  return path === "/v1/auth/login" || path === "/v1/auth/register" || path === "/v1/auth/refresh";
}

export async function rateLimit(c: Context, next: Next): Promise<Response | void> {
  const path = c.req.path;
  if (path === "/health" || path === "/metrics") return next();
  const max = isAuthPath(path) ? config.rateLimit.authMax : config.rateLimit.max;
  const now = Date.now();
  const key = `${clientAddress(c)}:${isAuthPath(path) ? "auth" : "api"}`;
  const current = buckets.get(key);
  const bucket = !current || current.resetAt <= now
    ? { count: 0, resetAt: now + config.rateLimit.windowSec * 1000 }
    : current;
  bucket.count += 1;
  buckets.set(key, bucket);
  // Bound memory if a long-running public deployment sees many one-off IPs.
  if (buckets.size > 10_000) {
    for (const [candidate, value] of buckets) {
      if (value.resetAt <= now) buckets.delete(candidate);
    }
  }
  c.header("X-RateLimit-Limit", String(max));
  c.header("X-RateLimit-Remaining", String(Math.max(0, max - bucket.count)));
  c.header("X-RateLimit-Reset", String(Math.ceil(bucket.resetAt / 1000)));
  if (bucket.count > max) {
    recordError("rate_limited");
    c.header("Retry-After", String(Math.ceil((bucket.resetAt - now) / 1000)));
    return c.json({ error: "rate_limited", message: "Too many requests" }, 429);
  }
  return next();
}

export async function securityHeaders(c: Context, next: Next): Promise<void> {
  await next();
  c.header("X-Content-Type-Options", "nosniff");
  c.header("X-Frame-Options", "DENY");
  c.header("Referrer-Policy", "no-referrer");
  c.header("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  c.header("Cache-Control", "no-store");
  if (config.nodeEnv === "production") {
    c.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
  }
}
