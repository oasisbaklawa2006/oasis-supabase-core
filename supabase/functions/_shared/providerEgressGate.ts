/**
 * Source-only Buyer #64 / Core #520 outbound gate.
 *
 * Supabase injects SUPABASE_URL and DENO_DEPLOYMENT_ID into hosted Edge
 * runtimes. They cannot be supplied by HTTP callers. Require both independent
 * hosted identity signals before a production messaging/AI provider request.
 *
 * No request header, recipient, API key, JWT claim, UAT flag or service-role
 * context can bypass this gate. Disposable previews and local runtimes remain
 * hard-denied until a separately reviewed sandbox-only release is approved.
 *
 * IMPORTANT: This is a per-call-site guard, not a platform-wide egress firewall.
 * Every external provider call site must be migrated and runtime certified.
 */
const PRODUCTION_PROJECT_REF = "tcxvcatsqqertcnycuop";
const PRODUCTION_SUPABASE_URL =
  `https://${PRODUCTION_PROJECT_REF}.supabase.co`;

// Hosted DENO_DEPLOYMENT_ID: {project_ref}_{function_uuid}_{version}.
// A missing or malformed deployment identity is never treated as production.
const productionDeploymentPattern = new RegExp(
  `^${PRODUCTION_PROJECT_REF}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_[1-9][0-9]*$`,
);

/** Opaque non-sensitive denial reason; no URL, provider key or recipient data. */
export const PROVIDER_EGRESS_BLOCKED = "PROVIDER_EGRESS_BLOCKED";

/**
 * Evaluate trusted *runtime* identity, never an HTTP/body/JWT-provided value.
 * Exact equality rejects accidental preview URLs, local hosts and URL suffixes.
 */
export function isProductionProviderEgressAllowed(
  supabaseUrl: unknown,
  deploymentId: unknown,
): boolean {
  return supabaseUrl === PRODUCTION_SUPABASE_URL &&
    typeof deploymentId === "string" &&
    productionDeploymentPattern.test(deploymentId);
}

/** Resolve the two Supabase-managed hosted runtime identity signals. */
export function productionProviderEgressAllowed(): boolean {
  return isProductionProviderEgressAllowed(
    Deno.env.get("SUPABASE_URL"),
    Deno.env.get("DENO_DEPLOYMENT_ID"),
  );
}

/**
 * Gate the last outbound network boundary. The dependency-injected fetch
 * exists for deterministic no-network tests, not for caller configuration.
 * Requires production identity before examining or invoking the provider.
 */
export async function guardedProviderFetch(
  url: string,
  init: RequestInit,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  if (!productionProviderEgressAllowed()) {
    throw new Error(PROVIDER_EGRESS_BLOCKED);
  }
  return await fetchImpl(url, init);
}
