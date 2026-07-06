import { productFamilyKey } from "./productFamilies.ts";
import type { RuntimeCatalog, RuntimeCatalogProduct } from "./types.ts";

export type ScoredCandidateLike = {
  product_id: string;
  sku: string;
  product_name: string;
  matched_term: string;
  match_source: string;
  confidence: number;
};

export type CollapsedCandidatesResult<T extends ScoredCandidateLike> = {
  collapsed: T[];
  rawCount: number;
  logicalGroupCount: number;
  collapsedDuplicateCount: number;
};

function normalizeLabel(value: string | null | undefined): string {
  return (value ?? "").trim().toLowerCase().replace(/\s+/g, " ");
}

/** Extract trailing numeric serial from Oasis SKUs e.g. ...-0017 → 17 */
export function skuSerial(sku: string): number {
  const match = sku.match(/(\d+)\s*$/);
  return match ? Number(match[1]) : 0;
}

/** Pack / variant bucket so bulk vs gift remain distinct logical groups. */
export function packVariantIndicator(product: RuntimeCatalogProduct): string {
  const hay = [
    product.sku,
    product.name,
    product.product_name,
    product.short_name,
    product.packaging_code,
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  if (hay.includes("gift pack") || hay.includes("gift") && hay.includes("pc")) return "gift_pack";
  if (product.sku.includes("MAAPET") || hay.includes("maapet")) return "maapet";
  if (product.sku.includes("BULK") || hay.includes(" bulk")) return "bulk";
  if (product.packaging_code) return normalizeLabel(product.packaging_code);

  const skuSegment = product.sku.split("-").find((s) =>
    ["BULK", "MAAPET", "LOOSE", "TRAY1KG", "RBOX", "MAPTRAY"].includes(s.toUpperCase()),
  );
  if (skuSegment) return skuSegment.toLowerCase();

  return "default";
}

/** Stable logical group key — duplicate catalogue rows share this key. */
export function logicalGroupKey(product: RuntimeCatalogProduct): string {
  const family = productFamilyKey(product);
  if (family) {
    return `family::${family}`;
  }

  const name = normalizeLabel(product.product_name ?? product.name);
  const short = normalizeLabel(product.short_name);
  const category = normalizeLabel(product.category);
  const subcategory = normalizeLabel(product.subcategory);
  const pack = packVariantIndicator(product);
  return [name, short, category, subcategory, pack].join("::");
}

function isActiveProduct(product: RuntimeCatalogProduct | undefined): boolean {
  if (!product) return false;
  if (product.archived_at) return false;
  if (product.is_active === false) return false;
  return true;
}

function timestampMs(value: string | null | undefined): number {
  if (!value) return 0;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : 0;
}

function exactAliasMatchScore(rawUtterance: string, matchedTerm: string): number {
  const raw = rawUtterance.trim().toLowerCase().replace(/\s+/g, " ");
  const term = matchedTerm.trim().toLowerCase().replace(/\s+/g, " ");
  if (raw === term) return 2;
  const rawSorted = [...raw.split(" ")].sort().join(" ");
  const termSorted = [...term.split(" ")].sort().join(" ");
  return rawSorted === termSorted ? 1 : 0;
}

function compareRepresentatives<T extends ScoredCandidateLike>(
  a: T,
  b: T,
  productA: RuntimeCatalogProduct | undefined,
  productB: RuntimeCatalogProduct | undefined,
  rawUtterance: string,
): number {
  const activeA = isActiveProduct(productA) ? 1 : 0;
  const activeB = isActiveProduct(productB) ? 1 : 0;
  if (activeA !== activeB) return activeB - activeA;

  const updatedA = Math.max(timestampMs(productA?.updated_at), timestampMs(productA?.created_at));
  const updatedB = Math.max(timestampMs(productB?.updated_at), timestampMs(productB?.created_at));
  if (updatedA !== updatedB) return updatedB - updatedA;

  const serialA = skuSerial(a.sku);
  const serialB = skuSerial(b.sku);
  if (serialA !== serialB) return serialB - serialA;

  if (a.confidence !== b.confidence) return b.confidence - a.confidence;

  const aliasA = exactAliasMatchScore(rawUtterance, a.matched_term);
  const aliasB = exactAliasMatchScore(rawUtterance, b.matched_term);
  if (aliasA !== aliasB) return aliasB - aliasA;

  return a.sku.localeCompare(b.sku);
}

function pickGroupRepresentative<T extends ScoredCandidateLike>(
  group: T[],
  productById: Map<string, RuntimeCatalogProduct>,
  rawUtterance: string,
): T {
  return [...group].sort((a, b) =>
    compareRepresentatives(a, b, productById.get(a.product_id), productById.get(b.product_id), rawUtterance),
  )[0];
}

/**
 * Collapse duplicate/near-duplicate catalogue rows into one representative per logical group.
 * Ambiguity checks should run on collapsed groups, not raw product rows.
 */
export function collapseCandidatesByLogicalGroup<T extends ScoredCandidateLike>(
  candidates: T[],
  catalog: RuntimeCatalog,
  rawUtterance: string,
): CollapsedCandidatesResult<T> {
  const productById = new Map(catalog.products.map((p) => [p.id, p]));
  const byGroup = new Map<string, T[]>();

  for (const candidate of candidates) {
    const product = productById.get(candidate.product_id);
    const key = product ? logicalGroupKey(product) : `unknown::${candidate.product_id}`;
    const list = byGroup.get(key) ?? [];
    list.push(candidate);
    byGroup.set(key, list);
  }

  const collapsed: T[] = [];
  for (const group of byGroup.values()) {
    collapsed.push(pickGroupRepresentative(group, productById, rawUtterance));
  }

  collapsed.sort((a, b) => b.confidence - a.confidence);

  return {
    collapsed,
    rawCount: candidates.length,
    logicalGroupCount: collapsed.length,
    collapsedDuplicateCount: candidates.length - collapsed.length,
  };
}
