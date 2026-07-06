import type { ConfidenceBand, ResolverAction } from "./types.ts";

export function isAmbiguous(top: number, second: number | undefined, delta: number): boolean {
  return second != null && top - second < delta;
}

export function assignConfidenceBand(
  confidence: number,
  ambiguous: boolean,
  hasCandidates: boolean,
  highThreshold: number,
  minThreshold: number,
): ConfidenceBand {
  if (!hasCandidates || confidence < minThreshold || ambiguous) return "LOW";
  if (confidence >= highThreshold) return "HIGH";
  return "MEDIUM";
}

export function actionForBand(band: ConfidenceBand): ResolverAction {
  switch (band) {
    case "HIGH":
      return "auto_suggest";
    case "MEDIUM":
      return "operator_review";
    default:
      return "ask_clarification";
  }
}

export function buildReason(opts: {
  band: ConfidenceBand;
  ambiguous: boolean;
  confidence: number;
  minThreshold: number;
  matchSource?: string;
  matchedTerm?: string;
  resolvedSku?: string | null;
  candidateCount: number;
  logicalGroupCount?: number;
  collapsedDuplicateCount?: number;
}): string {
  const {
    band,
    ambiguous,
    confidence,
    minThreshold,
    matchSource,
    matchedTerm,
    resolvedSku,
    candidateCount,
    logicalGroupCount,
    collapsedDuplicateCount = 0,
  } = opts;

  const groupCount = logicalGroupCount ?? candidateCount;

  if (candidateCount === 0) {
    return "No product matched the normalized utterance.";
  }
  if (ambiguous) {
    if (collapsedDuplicateCount > 0) {
      return `Multiple product groups score within ambiguity delta — ${groupCount} group(s) need clarification (duplicate catalogue rows collapsed).`;
    }
    return `Multiple product groups score within ambiguity delta — ${groupCount} group(s) need clarification.`;
  }
  if (collapsedDuplicateCount > 0 && band === "HIGH") {
    if (resolvedSku && matchSource === "sku") {
      return `Matched SKU exactly: ${resolvedSku} (duplicate catalogue rows collapsed into product groups).`;
    }
    if (matchedTerm && matchSource) {
      return `Matched via ${matchSource}: "${matchedTerm}" (${band} confidence ${confidence.toFixed(2)}; duplicate catalogue rows collapsed).`;
    }
  }
  if (confidence < minThreshold) {
    return `Best confidence ${confidence.toFixed(2)} is below ${minThreshold} threshold.`;
  }
  if (resolvedSku && matchSource === "sku") {
    return `Matched SKU exactly: ${resolvedSku}`;
  }
  if (matchedTerm && matchSource) {
    return `Matched via ${matchSource}: "${matchedTerm}" (${band} confidence ${confidence.toFixed(2)})`;
  }
  return `Resolved with ${band} confidence ${confidence.toFixed(2)}`;
}
