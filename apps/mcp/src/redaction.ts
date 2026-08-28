const REDACTED = "[REDACTED]";

export type RedactionContext = "diagnostic" | "agent-response";

const SENSITIVE_FIELD_NAMES = new Set([
  "authorization",
  "proxyauthorization",
  "claimtoken",
  "lease",
  "key",
  "token",
]);

const SENSITIVE_FIELD_SUFFIXES = [
  "leaseid",
  "leasetoken",
  "apikey",
  "agentkey",
  "secretkey",
  "clientsecret",
  "privatekey",
  "accesstoken",
  "refreshtoken",
  "sessiontoken",
  "authtoken",
  "password",
  "passphrase",
  "secret",
  "capability",
] as const;

function normalizedFieldName(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function isSensitiveFieldName(
  name: string,
  context: RedactionContext = "diagnostic",
): boolean {
  const normalized = normalizedFieldName(name);
  return (
    SENSITIVE_FIELD_NAMES.has(normalized) ||
    SENSITIVE_FIELD_SUFFIXES.some((suffix) => normalized.endsWith(suffix)) ||
    (context === "diagnostic" &&
      (normalized === "transcript" || normalized.endsWith("transcript")))
  );
}

function redactEmbeddedFieldAssignments(
  value: string,
  context: RedactionContext,
): string {
  const assignmentPattern =
    /(^|[\s{(\[,;.?&:'"])(?:\\?(["'])([A-Za-z][A-Za-z0-9_-]*)\\?\2|([A-Za-z][A-Za-z0-9_-]*))\s*[:=]\s*((?:Bearer|Basic)\s+(?:\[REDACTED\]|[A-Za-z0-9._~+/=-]+)|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\\".*?\\"|\\'.*?\\'|[^\s,;{}()\[\]"'&?#|]+)/gim;

  return value.replace(
    assignmentPattern,
    (
      match,
      _prefix: string,
      _quote: string | undefined,
      quotedFieldName: string | undefined,
      unquotedFieldName: string | undefined,
      rawFieldValue: string,
    ) => {
      const fieldName = quotedFieldName ?? unquotedFieldName;
      const sanitizedValue = isSensitiveFieldName(fieldName, context)
        ? REDACTED
        : redactEmbeddedFieldAssignments(rawFieldValue, context);
      return `${match.slice(0, match.length - rawFieldValue.length)}${sanitizedValue}`;
    },
  );
}

export function redactSensitiveText(
  value: string,
  context: RedactionContext = "diagnostic",
): string {
  const credentialsRedacted = value
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/\bvak_[A-Za-z0-9._-]{4,}\b/gi, REDACTED)
    .replace(/\bclaim_[A-Za-z0-9._-]{4,}\b/gi, REDACTED)
    .replace(/\blease_[A-Za-z0-9._-]{4,}\b/gi, REDACTED);
  const assignmentsRedacted = redactEmbeddedFieldAssignments(
    credentialsRedacted,
    context,
  );
  if (context === "agent-response") return assignmentsRedacted;
  return assignmentsRedacted.replace(
    /((?:["']?transcript["']?)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,}\]]+)/gi,
    "$1[REDACTED]",
  );
}

export function sanitizeSensitiveData(
  value: unknown,
  context: RedactionContext = "diagnostic",
): unknown {
  const seen = new WeakSet<object>();

  const visit = (current: unknown): unknown => {
    if (typeof current === "string") return redactSensitiveText(current, context);
    if (
      current === null ||
      typeof current === "number" ||
      typeof current === "boolean" ||
      typeof current === "undefined"
    ) {
      return current;
    }
    if (current instanceof Error) return redactSensitiveText(current.message, context);
    if (current instanceof Date) return current.toISOString();
    if (typeof current !== "object") return redactSensitiveText(String(current));
    if (seen.has(current)) return "[Circular]";
    seen.add(current);
    if (Array.isArray(current)) return current.map(visit);

    const sanitized: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(current)) {
      sanitized[key] = isSensitiveFieldName(key, context) ? REDACTED : visit(nested);
    }
    return sanitized;
  };

  return visit(value);
}

export function sanitizeAgentResponseData(value: unknown): unknown {
  return sanitizeSensitiveData(value, "agent-response");
}

export function safeErrorMessage(error: unknown): string {
  return redactSensitiveText(error instanceof Error ? error.message : String(error));
}
