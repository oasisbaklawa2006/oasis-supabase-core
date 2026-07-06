import type { RuntimeCatalogProduct } from "./types.ts";

/** Accepted SKUs for the Cashew Tart / Tart Cashew product family. */
export const CASHEW_TART_FAMILY_SKUS = [
  "OAS-AS-BKL-0020",
  "OAS-AS-BKL-CSH-BULK-0003",
  "OAS-AS-BKL-CSH-BULK-0004",
] as const;

const CASHEW_TOKENS = new Set(["cashew", "kaju"]);
const TART_TOKENS = new Set(["tart"]);

function nameTokens(product: RuntimeCatalogProduct): string[] {
  return [product.name, product.product_name, product.short_name]
    .filter(Boolean)
    .join(" ")
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean);
}

/** True when catalogue row is Cashew Tart / Tart Cashew (any pack variant). */
export function isCashewTartFamilyProduct(product: RuntimeCatalogProduct): boolean {
  return productFamilyKey(product) === "cashew_tart";
}

export function isCashewTartFamilySku(sku: string | null | undefined): boolean {
  if (!sku) return false;
  return (CASHEW_TART_FAMILY_SKUS as readonly string[]).includes(sku);
}

/**
 * Canonical product-family key for equivalent identity rows.
 * cashew tart = tart cashew = kaju tart = tart kaju → one family.
 */
export function productFamilyKey(product: RuntimeCatalogProduct): string | null {
  const tokens = nameTokens(product);
  const hasCashew = tokens.some((t) => CASHEW_TOKENS.has(t));
  const hasTart = tokens.some((t) => TART_TOKENS.has(t));
  if (hasCashew && hasTart) return "cashew_tart";
  return null;
}

/** Order-independent alias phrases equivalent within the cashew tart family. */
export function isCashewTartFamilyUtterance(text: string): boolean {
  const tokens = text
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .filter(Boolean);
  if (tokens.length < 2) return false;
  const hasCashew = tokens.some((t) => CASHEW_TOKENS.has(t));
  const hasTart = tokens.some((t) => TART_TOKENS.has(t));
  return hasCashew && hasTart;
}

export function cashewTartFamilyConfidenceBoost(
  rawUtterance: string,
  product: RuntimeCatalogProduct,
): number {
  if (!isCashewTartFamilyUtterance(rawUtterance)) return 0;
  if (!isCashewTartFamilyProduct(product)) return 0;
  return 0.14;
}
