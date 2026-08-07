import { Hono } from "hono";
import { requireUser, type AppVariables } from "../auth.js";
import { listDevPushes } from "../push.js";

const devRoutes = new Hono<{ Variables: AppVariables }>();

devRoutes.get("/pushes", requireUser, async (c) => {
  const user = c.get("user")!;
  const requestedLimit = Number(c.req.query("limit") ?? 100);
  const limit = Number.isFinite(requestedLimit) ? requestedLimit : 100;
  return c.json({ pushes: listDevPushes(user.userId, limit) });
});

export { devRoutes };
