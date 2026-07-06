import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { loadCatalogForEdge } from "./catalogLoader.ts";
import { resolveProductUtterance } from "./runtime/resolveProductUtterance.ts";
import type { ProductUtteranceResolution } from "./runtime/types.ts";

export type EdgeResolveResult = {
  resolver_status: "resolved" | "failed";
  resolver_result_json: ProductUtteranceResolution | null;
};

export async function resolveInboundAtEdge(
  admin: SupabaseClient,
  messageBody: string,
): Promise<EdgeResolveResult> {
  try {
    const catalog = await loadCatalogForEdge(admin);
    const resolution = resolveProductUtterance(messageBody, catalog);
    return {
      resolver_status: "resolved",
      resolver_result_json: resolution,
    };
  } catch {
    return {
      resolver_status: "failed",
      resolver_result_json: null,
    };
  }
}
