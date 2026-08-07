import { randomUUID } from "node:crypto";
import type { Context, Next } from "hono";
import { config } from "./config.js";

type Metric = { count: number; totalMs: number };
const requestMetrics = new Map<string, Metric>();
const errorMetrics = new Map<string, number>();

function metricFor(key: string): Metric {
  const current = requestMetrics.get(key) ?? { count: 0, totalMs: 0 };
  requestMetrics.set(key, current);
  return current;
}

export function recordError(kind: string): void {
  errorMetrics.set(kind, (errorMetrics.get(kind) ?? 0) + 1);
}

export async function requestTelemetry(c: Context, next: Next): Promise<void> {
  const requestId = c.req.header("x-request-id")?.slice(0, 120) || randomUUID();
  const started = performance.now();
  try {
    await next();
  } finally {
    const metric = metricFor(`${c.req.method} ${c.req.path}`);
    metric.count += 1;
    metric.totalMs += performance.now() - started;
    c.header("X-Request-Id", requestId);
    c.header("Server-Timing", `app;dur=${Math.round(performance.now() - started)}`);
  }
}

export function metricsText(): string {
  const lines = [
    "# HELP knock_knock_http_requests_total Total HTTP requests handled.",
    "# TYPE knock_knock_http_requests_total counter",
  ];
  for (const [route, metric] of requestMetrics) {
    const [method, ...pathParts] = route.split(" ");
    const path = pathParts.join(" ").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    lines.push(`knock_knock_http_requests_total{method="${method}",path="${path}"} ${metric.count}`);
  }
  lines.push("# HELP knock_knock_http_request_duration_ms_sum Total request duration in milliseconds.");
  lines.push("# TYPE knock_knock_http_request_duration_ms_sum counter");
  for (const [route, metric] of requestMetrics) {
    const [method, ...pathParts] = route.split(" ");
    const path = pathParts.join(" ").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    lines.push(`knock_knock_http_request_duration_ms_sum{method="${method}",path="${path}"} ${metric.totalMs.toFixed(2)}`);
  }
  lines.push("# HELP knock_knock_errors_total Total classified application errors.");
  lines.push("# TYPE knock_knock_errors_total counter");
  for (const [kind, count] of errorMetrics) {
    lines.push(`knock_knock_errors_total{kind="${kind.replace(/"/g, '\\"')}"} ${count}`);
  }
  return `${lines.join("\n")}\n`;
}

export function serviceInfo() {
  return {
    service: "@vab/api",
    version: config.serviceVersion,
    environment: config.nodeEnv,
  };
}
