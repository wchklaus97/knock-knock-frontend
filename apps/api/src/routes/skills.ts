import { Hono } from "hono";
import { z } from "zod";
import { requireUser, requireUserOrAgent, type AppVariables } from "../auth.js";
import { listSkills, upsertSkill } from "../skills.js";

const skillsRoutes = new Hono<{ Variables: AppVariables }>();

skillsRoutes.get("/", requireUserOrAgent, async (c) => {
  return c.json({ skills: listSkills() });
});

skillsRoutes.post("/", requireUser, async (c) => {
  const body = z
    .object({
      skill_id: z.string().min(1),
      template: z.string().min(1),
      facts_schema: z.array(z.string()).default([]),
      actions: z
        .array(
          z.object({
            id: z.string(),
            risk: z.enum(["low", "medium", "high", "destructive"]),
            confirm: z.boolean().optional(),
            title: z.string(),
            payload: z.record(z.unknown()).optional(),
          }),
        )
        .default([]),
      ttl: z
        .object({
          default_sec: z.number().int().positive().default(86_400),
          destructive_sec: z.number().int().positive().default(1_800),
        })
        .default({ default_sec: 86_400, destructive_sec: 1_800 }),
    })
    .safeParse(await c.req.json());

  if (!body.success) {
    return c.json({ error: "validation_error", message: body.error.message }, 400);
  }

  const skill = upsertSkill(body.data);
  return c.json({ skill }, 201);
});

export { skillsRoutes };
