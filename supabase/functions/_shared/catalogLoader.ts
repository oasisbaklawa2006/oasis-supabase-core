import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import type { RuntimeCatalog, RuntimeCatalogAlias, RuntimeCatalogProduct } from "./runtime/types.ts";

function aliasTextFromRow(row: Record<string, unknown>): string {
  const primary = row.alias ?? row.alias_text;
  return String(primary ?? "").trim();
}

function canonicalFromRow(row: Record<string, unknown>, fallback: string): string {
  const c = row.canonical_name;
  return (typeof c === "string" && c.trim()) || fallback;
}

/** Bulk catalogue loader for edge webhook resolver (read-only). */
export async function loadCatalogForEdge(admin: SupabaseClient): Promise<RuntimeCatalog> {
  const { data: products, error: productsError } = await admin
    .from("products")
    .select(
      "id, sku, name, product_name, short_name, category, subcategory, packaging_code, is_active, created_at",
    );

  if (productsError) throw productsError;

  const mappedProducts: RuntimeCatalogProduct[] = (products ?? []).map((p) => ({
    id: p.id,
    sku: p.sku,
    name: p.name ?? p.product_name ?? "Unnamed product",
    product_name: p.product_name ?? null,
    short_name: p.short_name ?? null,
    category: p.category ?? null,
    subcategory: p.subcategory ?? null,
    packaging_code: p.packaging_code ?? null,
    is_active: p.is_active ?? null,
    archived_at: null,
    created_at: p.created_at ?? null,
    updated_at: null,
  }));

  const { data: aliasRows, error: aliasError } = await admin
    .from("product_aliases")
    .select("product_id, alias_text, canonical_name, created_at");

  if (aliasError) throw aliasError;

  const aliases: RuntimeCatalogAlias[] = [];
  for (const row of aliasRows ?? []) {
    const product = mappedProducts.find((p) => p.id === row.product_id);
    if (!product) continue;
    const alias_text = aliasTextFromRow(row as Record<string, unknown>);
    if (!alias_text) continue;
    aliases.push({
      alias_text,
      canonical_name: canonicalFromRow(row as Record<string, unknown>, product.name),
      product_id: row.product_id,
      alias_type: null,
    });
  }

  return { products: mappedProducts, aliases };
}
