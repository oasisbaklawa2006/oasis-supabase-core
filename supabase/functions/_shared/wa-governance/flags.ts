/**
 * WhatsApp governance feature flags (PR-WA-02B).
 * Defaults are false — explicit env override required to enable risky paths.
 */

export const WA_FLAG_ENV = {
  /** Pipeline C: webhook aiParseOrder → direct orders / order_items writes */
  WEBHOOK_AUTO_ORDER_WRITES: "ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES",
  /** Automatic mutation of companies.account_manager_id from webhook/parser */
  WEBHOOK_OWNER_REASSIGNMENT: "ENABLE_WA_WEBHOOK_OWNER_REASSIGNMENT",
} as const;

export type EnvGetter = (name: string) => string | undefined;

/** True only when env is explicitly "true", "1", or "yes" (case-insensitive). */
export function parseEnvFlagTrue(value: string | undefined): boolean {
  if (!value) return false;
  const normalized = value.trim().toLowerCase();
  return normalized === "true" || normalized === "1" || normalized === "yes";
}

export function isWaWebhookAutoOrderWritesEnabled(getEnv: EnvGetter = defaultEnvGetter): boolean {
  return parseEnvFlagTrue(getEnv(WA_FLAG_ENV.WEBHOOK_AUTO_ORDER_WRITES));
}

export function isWaWebhookOwnerReassignmentEnabled(getEnv: EnvGetter = defaultEnvGetter): boolean {
  return parseEnvFlagTrue(getEnv(WA_FLAG_ENV.WEBHOOK_OWNER_REASSIGNMENT));
}

function defaultEnvGetter(name: string): string | undefined {
  const g = globalThis as {
    Deno?: { env?: { get: (key: string) => string | undefined } };
    process?: { env?: Record<string, string | undefined> };
  };
  if (g.Deno?.env?.get) {
    return g.Deno.env.get(name);
  }
  if (g.process?.env) {
    return g.process.env[name];
  }
  return undefined;
}
