/** Classify harness errors without leaking raw DB/corpus content into Git artifacts. */
export function classifyError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();
  if (lower.includes("duplicate key") || lower.includes("unique constraint")) {
    return "HARNESS_IDENTITY_COLLISION";
  }
  if (lower.includes("econnrefused") || lower.includes("cert_db_unavailable")) {
    return "CERT_DB_UNAVAILABLE";
  }
  if (
    lower.includes("production supabase") ||
    lower.includes("tcxvcatsqqertcnycuop")
  ) {
    return "PRODUCTION_TARGET_REJECTED";
  }
  if (
    lower.includes("non-local host") ||
    lower.includes("database target rejected")
  ) {
    return "CERT_DB_TARGET_REJECTED";
  }
  if (lower.includes("authorized corpus not found")) {
    return "CORPUS_NOT_MOUNTED";
  }
  if (lower.includes("missing observed result")) {
    return "MISSING_OBSERVED_RESULT";
  }
  return "CERT_EXECUTION_ERROR";
}

/** Strip PII patterns from free text before any diagnostic use. */
export function redactSensitiveText(value: string): string {
  return value
    .replace(/\+?\d{10,12}/g, "[PHONE]")
    .replace(/[\w.-]+@[\w.-]+\.\w+/g, "[EMAIL]")
    .replace(/₹[\d,]+/g, "[AMOUNT]")
    .replace(/\b\d{12,18}\b/g, "[NUMERIC]");
}

export function sanitizeDefectRootCause(
  observedCoreOutcome: string | null,
  autoActioned: boolean,
  error: string | null | undefined,
): string {
  if (error) return classifyError(new Error(error));
  return `OUTCOME_${observedCoreOutcome ?? "NULL"}_AUTO_${
    autoActioned ? "YES" : "NO"
  }`;
}
