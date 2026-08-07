import { config } from "./config.js";
import { getDb, nowIso } from "./db.js";

export type SkillAction = {
  id: string;
  risk: "low" | "medium" | "high" | "destructive";
  confirm?: boolean;
  title: string;
  payload?: Record<string, unknown>;
};

export type SkillDef = {
  skill_id: string;
  template: string;
  facts_schema: string[];
  actions: SkillAction[];
  ttl: { default_sec: number; destructive_sec: number };
};

const DEPLOY_RESULT: SkillDef = {
  skill_id: "deploy.result",
  template: "{{service}} 在 {{env}} 部署{{status}}",
  facts_schema: ["service", "status", "env"],
  actions: [
    { id: "rollback", risk: "destructive", confirm: true, title: "回滚" },
    { id: "ack", risk: "low", confirm: false, title: "已知晓" },
  ],
  ttl: { default_sec: 86_400, destructive_sec: 1_800 },
};

export function seedSkills(): void {
  const database = getDb();
  const existing = database
    .prepare("SELECT skill_id FROM skills WHERE skill_id = ?")
    .get(DEPLOY_RESULT.skill_id);
  if (existing) return;
  upsertSkill(DEPLOY_RESULT);
}

export function upsertSkill(skill: SkillDef): SkillDef {
  const database = getDb();
  const createdAt = nowIso();
  database
    .prepare(
      `INSERT INTO skills (skill_id, template, facts_schema_json, actions_json, ttl_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(skill_id) DO UPDATE SET
         template = excluded.template,
         facts_schema_json = excluded.facts_schema_json,
         actions_json = excluded.actions_json,
         ttl_json = excluded.ttl_json`,
    )
    .run(
      skill.skill_id,
      skill.template,
      JSON.stringify(skill.facts_schema),
      JSON.stringify(skill.actions),
      JSON.stringify(skill.ttl),
      createdAt,
    );
  return normalizeSkill(skill);
}

export function listSkills(): SkillDef[] {
  const rows = getDb()
    .prepare("SELECT skill_id, template, facts_schema_json, actions_json, ttl_json FROM skills")
    .all() as Array<{
    skill_id: string;
    template: string;
    facts_schema_json: string;
    actions_json: string;
    ttl_json: string;
  }>;
  return rows.map((r) =>
    normalizeSkill({
      skill_id: r.skill_id,
      template: r.template,
      facts_schema: JSON.parse(r.facts_schema_json) as string[],
      actions: JSON.parse(r.actions_json) as SkillAction[],
      ttl: JSON.parse(r.ttl_json) as SkillDef["ttl"],
    }),
  );
}

export function getSkill(skillId: string): SkillDef | null {
  const row = getDb()
    .prepare(
      "SELECT skill_id, template, facts_schema_json, actions_json, ttl_json FROM skills WHERE skill_id = ?",
    )
    .get(skillId) as
    | {
        skill_id: string;
        template: string;
        facts_schema_json: string;
        actions_json: string;
        ttl_json: string;
      }
    | undefined;
  if (!row) return null;
  return normalizeSkill({
    skill_id: row.skill_id,
    template: row.template,
    facts_schema: JSON.parse(row.facts_schema_json) as string[],
    actions: JSON.parse(row.actions_json) as SkillAction[],
    ttl: JSON.parse(row.ttl_json) as SkillDef["ttl"],
  });
}

function normalizeSkill(skill: SkillDef): SkillDef {
  return {
    ...skill,
    ttl: {
      default_sec: Math.min(Math.max(1, skill.ttl.default_sec || config.maxTtlSec), config.maxTtlSec),
      destructive_sec: Math.min(
        Math.max(1, skill.ttl.destructive_sec || config.maxDestructiveSec),
        config.maxDestructiveSec,
      ),
    },
  };
}

export function renderSummary(template: string, facts: Record<string, unknown>): string {
  return template.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, key: string) => {
    const value = facts[key];
    return value == null ? "" : String(value);
  });
}

export function toVoiceScript(summary: string, maxLen = 80): string {
  const trimmed = summary.trim();
  if (trimmed.length <= maxLen) return trimmed;
  return `${trimmed.slice(0, maxLen - 1)}…`;
}

export type ActionInput =
  | string
  | {
      id: string;
      risk?: SkillAction["risk"];
      confirm?: boolean;
      title?: string;
      payload?: Record<string, unknown>;
    };

export function resolveSkillActions(
  skill: SkillDef,
  requested: ActionInput[] | undefined,
): SkillAction[] {
  if (!requested || requested.length === 0) return [];
  const byId = new Map(skill.actions.map((a) => [a.id, a]));
  const out: SkillAction[] = [];
  for (const item of requested) {
    if (typeof item === "string") {
      const found = byId.get(item);
      if (found) out.push(found);
    } else if (item?.id) {
      const base = byId.get(item.id);
      const risk = item.risk ?? base?.risk ?? "low";
      out.push({
        id: item.id,
        risk,
        confirm: item.confirm ?? base?.confirm ?? risk === "destructive",
        title: item.title ?? base?.title ?? item.id,
        payload: item.payload ?? base?.payload,
      });
    }
  }
  return out;
}

export function actionNeedsConfirm(action: SkillAction): boolean {
  return action.risk === "destructive" || action.confirm === true;
}
