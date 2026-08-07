import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { AppVariables } from "./auth.js";
import { config } from "./config.js";
import { getDb } from "./db.js";
import { actionsRoutes } from "./routes/actions.js";
import { agentsRoutes } from "./routes/agents.js";
import { authRoutes } from "./routes/auth.js";
import { devRoutes } from "./routes/dev.js";
import { pairingRoutes } from "./routes/pairing.js";
import { phoneRoutes } from "./routes/phone.js";
import { sessionsRoutes } from "./routes/sessions.js";
import { skillsRoutes } from "./routes/skills.js";
import { isApnsReady } from "./apns.js";
import { metricsText, requestTelemetry, serviceInfo } from "./observability.js";
import { rateLimit, securityHeaders } from "./security.js";
import { seedSkills } from "./skills.js";

getDb();
seedSkills();

const app = new Hono<{ Variables: AppVariables }>();

app.use("*", cors({ origin: config.corsOrigin }));
app.use("*", logger());
app.use("*", requestTelemetry);
app.use("*", rateLimit);
app.use("*", securityHeaders);

app.get("/health", (c) =>
  c.json({
    ok: true,
    ...serviceInfo(),
    push_mode: config.pushMode,
    apns_ready: isApnsReady(),
    time: new Date().toISOString(),
  }),
);

app.get("/metrics", (c) => {
  c.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
  return c.body(metricsText());
});

app.route("/v1/auth", authRoutes);
app.route("/v1/agents", agentsRoutes);
app.route("/v1/pairing", pairingRoutes);
app.route("/v1/skills", skillsRoutes);
app.route("/v1/sessions", sessionsRoutes);
app.route("/v1/actions", actionsRoutes);
app.route("/v1/phone", phoneRoutes);
app.route("/v1/dev", devRoutes);

app.onError((err, c) => {
  console.error(`[api] request_id=${c.res.headers.get("x-request-id") ?? "unknown"}`, err);
  console.error(err);
  return c.json({ error: "internal_error", message: err.message }, 500);
});

console.log(`[vab/api] db=${config.databasePath}`);
console.log(`[vab/api] listening on ${config.publicBaseUrl} (port ${config.port})`);

// Bind all interfaces so a physical iPhone on the same LAN can reach the Mac.
serve({
  fetch: app.fetch,
  hostname: "0.0.0.0",
  port: config.port,
});

export { app };
