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

/** Fixed diagnostic templates that never embed raw corpus/DB text. */
const KNOWN_SAFE_VIOLATION =
  /^[^:]+:\s(?:wrong (?:customer|branch|SKU|quantity|UOM) auto-action|invented commercial terms leaked|second execution was not idempotent|replay core outcome mismatch|missing observed result)$|^(?:dangerous automated commercial false positives|false orders|outcome mismatches|auto-action mismatches|missing potential-order accounting|pairing violations):/;

/** Strip raw runtime/DB text from violation lines before persisting reports. */
export function sanitizeViolationLine(violation: string): string {
  const executionPrefix = violation.match(/^([^:]+): execution error: /);
  if (executionPrefix) {
    const caseId = executionPrefix[1];
    const errorText = violation.slice(executionPrefix[0].length);
    return `${caseId}: ${classifyError(new Error(errorText))}`;
  }
  if (/\+?\d{10,12}|utr|neft|imps|rtgs/i.test(violation)) {
    return classifyError(new Error(violation));
  }
  if (KNOWN_SAFE_VIOLATION.test(violation)) {
    return violation;
  }
  const casePrefix = violation.match(/^([^:]+): /);
  if (casePrefix) {
    return `${casePrefix[1]}: CERTIFICATION_VIOLATION`;
  }
  return "CERTIFICATION_VIOLATION";
}

export function sanitizeViolationLines(violations: string[]): string[] {
  return violations.map(sanitizeViolationLine);
}

/** Returns true when serialized report JSON contains no obvious PII markers. */
export function reportJsonIsPrivacySafe(serialized: string): boolean {
  return !/(?:\+?\d{10,12}|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|₹[\d,]+)/i
    .test(
      serialized,
    );
}
