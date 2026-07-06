import { buildCatalogLexicon, type CatalogLexiconEntry } from "./catalogLexicon.ts";
import { collapseCandidatesByLogicalGroup } from "./candidateGrouping.ts";
import { cashewTartFamilyConfidenceBoost } from "./productFamilies.ts";
import {
  actionForBand,
  assignConfidenceBand,
  buildReason,
  isAmbiguous,
} from "./confidenceBands.ts";
import { normalizeUtterance } from "./normalizeUtterance.ts";
import { extractOrderQuantity } from "./parseOrderQuantity.ts";
import {
  bulkPhraseBoost,
  cheeseIntentBoost,
  exactSkuScore,
  exactUtteranceAliasBoost,
  frozenIntentBoost,
  packCountBoost,
  tokenOverlapScore,
} from "./scoring.ts";
import type {
  MatchSource,
  ProductUtteranceResolution,
  RuntimeAlternative,
  RuntimeCatalog,
  RuntimeResolverConfig,
} from "./types.ts";
import { DEFAULT_RUNTIME_RESOLVER_CONFIG } from "./types.ts";

type ScoredCandidate = {
  product_id: string;
  sku: string;
  product_name: string;
  matched_term: string;
  match_source: MatchSource;
  confidence: number;
};

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean);
}

function pickExactAliasWinner(
  catalog: RuntimeCatalog,
  ranked: ScoredCandidate[],
  raw: string,
): ScoredCandidate | undefined {
  const r = raw.trim().toLowerCase().replace(/\s+/g, " ");

  for (const alias of catalog.aliases) {
    const aliasText = alias.alias_text.trim().toLowerCase().replace(/\s+/g, " ");
    if (aliasText !== r) continue;
    const rankedMatch = ranked.find((c) => c.product_id === alias.product_id);
    if (rankedMatch) {
      return {
        ...rankedMatch,
        matched_term: alias.alias_text,
        match_source: "alias",
      };
    }
  }

  const rSorted = [...r.split(/\s+/)].sort().join(" ");
  const sortedMatches = ranked.filter((c) => {
    if (c.match_source !== "alias" && c.match_source !== "short_name") return false;
    const tSorted = [...c.matched_term.trim().toLowerCase().split(/\s+/)].sort().join(" ");
    return tSorted === rSorted;
  });
  return sortedMatches.length === 1 ? sortedMatches[0] : undefined;
}

function considerCandidate(map: Map<string, ScoredCandidate>, candidate: ScoredCandidate) {
  const existing = map.get(candidate.product_id);
  if (!existing || candidate.confidence > existing.confidence) {
    map.set(candidate.product_id, candidate);
  }
}

function scoreEntryTerms(
  entry: CatalogLexiconEntry,
  normalized: ReturnType<typeof normalizeUtterance>,
  catalog: RuntimeCatalog,
): ScoredCandidate | null {
  const queryVariants = [
    normalized.normalized_text,
    normalized.alias_match_text,
    normalized.tokens.join(" "),
  ].filter(Boolean);

  let best: ScoredCandidate | null = null;

  for (const term of entry.terms) {
    let score = 0;

    if (term.source === "sku") {
      score = Math.max(...queryVariants.map((q) => exactSkuScore(q, term.text)));
    } else {
      for (const qv of queryVariants) {
        const qTokens = tokenize(qv);
        const overlap = tokenOverlapScore(qTokens.length ? qTokens : normalized.tokens, term.tokens);
        score = Math.max(score, overlap);
      }
    }

    if (score <= 0) continue;

    let capped =
      term.source === "sku"
        ? score
        : Math.min(0.97, score + (term.source === "alias" ? 0.02 : 0));

    if (term.source === "alias") {
      capped = Math.min(1, capped + exactUtteranceAliasBoost(normalized.raw, term.text));
    }
    capped = Math.min(1, capped + bulkPhraseBoost(normalized.raw, entry.resolved_name, entry.sku));

    const candidate: ScoredCandidate = {
      product_id: entry.product_id,
      sku: entry.sku,
      product_name: entry.resolved_name,
      matched_term: term.text,
      match_source: term.source,
      confidence: capped,
    };

    if (!best || candidate.confidence > best.confidence) {
      best = candidate;
    }
  }

  if (!best) return null;

  let confidence = best.confidence;
  confidence += packCountBoost(normalized.pack_count, entry.search_text, entry.sku);
  confidence += frozenIntentBoost(normalized.tokens, entry.search_text);
  confidence += cheeseIntentBoost(normalized.tokens, entry.search_text);
  const product = catalog.products.find((p) => p.id === entry.product_id);
  if (product) {
    confidence += cashewTartFamilyConfidenceBoost(normalized.raw, product);
  }
  confidence = Math.min(1, Math.max(0, confidence));

  return { ...best, confidence };
}

function isMidyaSingleTokenAmbiguous(
  normalized: ReturnType<typeof normalizeUtterance>,
  catalog: RuntimeCatalog,
): boolean {
  if (normalized.pack_count) return false;
  if (normalized.tokens.length !== 1) return false;
  const token = normalized.tokens[0];
  if (!["midya", "midea", "mediya"].includes(token)) return false;

  const midyaProducts = catalog.products.filter((p) => p.name.toLowerCase().includes("midya"));
  const bulk = midyaProducts.filter((p) => p.name.toLowerCase().includes("bulk"));
  const gift = midyaProducts.filter(
    (p) => p.name.toLowerCase().includes("gift pack") || p.name.toLowerCase().includes("maapet"),
  );
  return bulk.length >= 1 && gift.length >= 1;
}

function isNutAsiyahAmbiguous(
  normalized: ReturnType<typeof normalizeUtterance>,
  catalog: RuntimeCatalog,
): boolean {
  const tokens = normalized.tokens;
  if (tokens.length !== 2) return false;

  const isAsiyah = (t: string) => ["asiyah", "assiyah", "assiya"].includes(t);
  const isCashew = (t: string) => ["cashew", "kaju"].includes(t);
  const isPistachio = (t: string) => ["pistachio", "pista"].includes(t);

  // Dedicated alias order e.g. "assiyah pista" — resolved via exact alias, not generic ambiguity.
  if (isAsiyah(tokens[0]) && (isCashew(tokens[1]) || isPistachio(tokens[1]))) {
    return false;
  }

  if (!isAsiyah(tokens[1])) return false;
  const wantsCashew = isCashew(tokens[0]);
  const wantsPistachio = isPistachio(tokens[0]);
  if (!wantsCashew && !wantsPistachio) return false;

  const qualifiers = ["mor", "chocolate", "beetroot"];
  if (qualifiers.some((q) => normalized.normalized_text.includes(q))) return false;

  const asiyahProducts = catalog.products.filter((p) => {
    const name = p.name.toLowerCase();
    if (!name.includes("asiyah")) return false;
    if (wantsCashew && name.includes("cashew")) return true;
    if (wantsPistachio && name.includes("pistachio")) return true;
    return false;
  });

  return asiyahProducts.length >= 2;
}

/**
 * Phase 2A identify-only resolver — read-only catalogue, no writes.
 */
export function resolveProductUtterance(
  input: string,
  catalog: RuntimeCatalog,
  config: RuntimeResolverConfig = DEFAULT_RUNTIME_RESOLVER_CONFIG,
): ProductUtteranceResolution {
  const normalized = normalizeUtterance(input);
  const lexicon = buildCatalogLexicon(catalog);
  const candidateMap = new Map<string, ScoredCandidate>();

  if (!normalized.normalized_text) {
    return {
      query: input,
      normalized_text: "",
      resolved_product_id: null,
      resolved_sku: null,
      resolved_name: null,
      confidence: 0,
      confidence_band: "LOW",
      action: "ask_clarification",
      reason: "No product matched the normalized utterance.",
      clarification_required: true,
      alternatives: [],
      pack_count: normalized.pack_count,
      order_quantity: extractOrderQuantity(input),
    };
  }

  for (const entry of lexicon) {
    const scored = scoreEntryTerms(entry, normalized, catalog);
    if (scored) considerCandidate(candidateMap, scored);
  }

  let ranked = Array.from(candidateMap.values()).sort((a, b) => b.confidence - a.confidence);
  const {
    collapsed: logicalRanked,
    rawCount,
    logicalGroupCount,
    collapsedDuplicateCount,
  } = collapseCandidatesByLogicalGroup(ranked, catalog, normalized.raw);
  ranked = logicalRanked;

  const midyaAmbiguous = isMidyaSingleTokenAmbiguous(normalized, catalog);
  const exactWinner = midyaAmbiguous ? undefined : pickExactAliasWinner(catalog, ranked, normalized.raw);
  const top = exactWinner ?? ranked[0];
  const second = exactWinner
    ? ranked.find((r) => r.product_id !== exactWinner.product_id)
    : ranked[1];

  const asiyahAmbiguous = isNutAsiyahAmbiguous(normalized, catalog);
  const deltaAmbiguous =
    !exactWinner && top && second
      ? isAmbiguous(top.confidence, second.confidence, config.ambiguity_delta)
      : false;

  const ambiguous = !exactWinner && (midyaAmbiguous || asiyahAmbiguous || deltaAmbiguous);
  const hasCandidates = ranked.length > 0;
  let confidence = top?.confidence ?? 0;

  if (ambiguous && top) {
    confidence = Math.min(confidence, config.min_threshold - 0.01);
  }

  const confidence_band = assignConfidenceBand(
    confidence,
    ambiguous,
    hasCandidates,
    config.high_threshold,
    config.min_threshold,
  );
  const action = actionForBand(confidence_band);
  const clarification_required = action === "ask_clarification";

  const alternatives: RuntimeAlternative[] = ranked.slice(0, config.max_candidates).map((r) => ({
    product_id: r.product_id,
    sku: r.sku,
    product_name: r.product_name,
    confidence: Number(r.confidence.toFixed(4)),
    matched_term: r.matched_term,
    match_source: r.match_source,
  }));

  const reason = buildReason({
    band: confidence_band,
    ambiguous,
    confidence,
    minThreshold: config.min_threshold,
    matchSource: top?.match_source,
    matchedTerm: top?.matched_term,
    resolvedSku: clarification_required ? null : top?.sku,
    candidateCount: rawCount,
    logicalGroupCount,
    collapsedDuplicateCount,
  });

  return {
    query: input,
    normalized_text: normalized.normalized_text,
    resolved_product_id: clarification_required ? null : (top?.product_id ?? null),
    resolved_sku: clarification_required ? null : (top?.sku ?? null),
    resolved_name: clarification_required ? null : (top?.product_name ?? null),
    confidence: Number(confidence.toFixed(4)),
    confidence_band,
    action,
    reason,
    clarification_required,
    alternatives,
    pack_count: normalized.pack_count,
    order_quantity: extractOrderQuantity(input),
  };
}
