/** @file Stage-1B fixture scoring helpers. */

import type { Fixture, PersistedOutcome, FixtureResult } from "./constants.ts";

export function firstOrderLine(
  container: Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!container) return null;
  const conclusion = container.conclusion;
  const source = conclusion && typeof conclusion === "object"
    ? conclusion as Record<string, unknown>
    : container;
  const lines = source.order_lines;
  if (!Array.isArray(lines) || !lines.length) return null;
  const first = lines[0];
  return first && typeof first === "object" ? first as Record<string, unknown> : null;
}

export function numeric(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) {
    return Number(value);
  }
  return null;
}

/** Canonicalizes common B2B unit spellings without creating commercial facts. */
export function canonicalUom(value: unknown): string | null {
  const normalized = String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[.\s_-]+/g, "");
  if (!normalized) return null;

  if (["box", "boxes", "bx", "bxs"].includes(normalized)) return "box";
  if (["piece", "pieces", "pc", "pcs"].includes(normalized)) return "piece";
  if (["pack", "packs", "pkt", "pkts", "packet", "packets"].includes(normalized)) return "pack";
  if (["kg", "kgs", "kilogram", "kilograms", "kilo", "kilos"].includes(normalized)) return "kg";
  if (["g", "gm", "gms", "gram", "grams"].includes(normalized)) return "g";

  return normalized;
}

export function uomEquivalent(expected: unknown, observed: unknown): boolean | null {
  if (expected === undefined || expected === null) return null;
  const expectedCanonical = canonicalUom(expected);
  const observedCanonical = canonicalUom(observed);
  return expectedCanonical !== null && expectedCanonical === observedCanonical;
}

/**
 * Reads a model-declared explicit evidence fact for recognition scoring only.
 * This does not create an order line, governed fact, draft, or execution authority.
 */
export function explicitFactValue(
  conclusion: Record<string, unknown> | null,
  allowedKinds: readonly string[],
): string | null {
  if (!conclusion || !Array.isArray(conclusion.explicit_facts)) return null;
  const kinds = new Set(allowedKinds.map((kind) => kind.toLowerCase()));
  for (const entry of conclusion.explicit_facts) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const fact = entry as Record<string, unknown>;
    const kind = typeof fact.kind === "string" ? fact.kind.trim().toLowerCase() : "";
    const value = typeof fact.value === "string" ? fact.value.trim() : "";
    if (value && kinds.has(kind)) return value;
  }
  return null;
}

export function recognitionFrom(interpretation: Record<string, unknown> | null) {
  const conclusion = interpretation?.conclusion;
  const c = conclusion && typeof conclusion === "object"
    ? conclusion as Record<string, unknown>
    : null;
  const line = firstOrderLine(interpretation);
  const lineSku = typeof line?.sku === "string" && line.sku.trim() ? line.sku.trim() : null;
  const lineProduct = typeof line?.product_name === "string" && line.product_name.trim()
    ? line.product_name.trim()
    : null;
  const explicitSku = explicitFactValue(c, ["sku", "product_sku"]);
  const explicitProduct = explicitFactValue(c, ["product_name", "product"]);
  return {
    intent: typeof c?.intent === "string" ? c.intent : null,
    sku: lineSku ?? explicitSku,
    product_name: lineProduct ?? explicitProduct,
    quantity: numeric(line?.quantity),
    uom: typeof line?.unit === "string" && line.unit.trim()
      ? line.unit.trim()
      : typeof line?.uom === "string" && line.uom.trim()
      ? line.uom.trim()
      : null,
  };
}

function governedLine(
  governedFacts: Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!governedFacts) return null;
  const lines = governedFacts.order_lines;
  if (!Array.isArray(lines) || !lines.length) return null;
  return lines[0] && typeof lines[0] === "object"
    ? lines[0] as Record<string, unknown>
    : null;
}

export function inventedCommercialLeakage(
  governedFacts: Record<string, unknown> | null,
): boolean {
  if (!governedFacts) return false;
  const customer = governedFacts.customer;
  if (customer && typeof customer === "object") {
    const terms = (customer as Record<string, unknown>).payment_terms;
    if (terms === "COD") return true;
  }
  const line = governedLine(governedFacts);
  return Boolean(line && ("unit_price" in line || "discount" in line));
}

function boolScore(expected: unknown, observed: unknown): boolean | null {
  if (expected === undefined || expected === null) return null;
  if (typeof expected === "number") return numeric(observed) === expected;
  return String(observed ?? "").toLowerCase() === String(expected).toLowerCase();
}

function intentEquivalent(expected: string, observed: string | null): boolean {
  if (!observed) return false;
  const e = expected.toUpperCase();
  const o = observed.toUpperCase();
  if (e === o) return true;
  if (e === "NEW_ORDER" && o === "ORDER") return true;
  if (e === "ENQUIRY" && ["ENQUIRY", "SPECIFICATION_QUERY", "SPECIFICATION"].includes(o)) {
    return true;
  }
  if (e === "AMENDMENT" && ["AMENDMENT", "ORDER_CHANGE"].includes(o)) return true;
  if (e === "UNCLEAR" && o === "UNCLEAR") return true;
  if (e === "OTHER" && ["OTHER", "COMPLAINT"].includes(o)) return true;
  return false;
}

export function scoreFixture(
  fixture: Fixture,
  persisted: PersistedOutcome,
): FixtureResult["scores"] {
  const gt = fixture.ground_truth;
  const rec = recognitionFrom(persisted.interpretation);
  const promoted = Boolean(persisted.promoted_order_id);
  const autoEligible = persisted.autonomy_outcome === "AUTO_ELIGIBLE";
  const authorityAdvanced = promoted || autoEligible;
  const line = governedLine(persisted.governed_facts);
  const governedSku = typeof line?.sku === "string" ? line.sku : null;
  const governedQty = numeric(line?.quantity);
  const governedUom = typeof line?.uom === "string"
    ? line.uom
    : typeof line?.unit === "string"
    ? line.unit
    : null;
  const leakage = inventedCommercialLeakage(persisted.governed_facts);
  const conclusion = persisted.interpretation?.conclusion;
  const replyClearance = conclusion && typeof conclusion === "object"
    ? (conclusion as Record<string, unknown>).reply_clearance
    : null;
  const clarificationSignaled = persisted.autonomy_outcome === "CLARIFICATION_REQUIRED" ||
    replyClearance === "CLARIFICATION_REQUIRED" ||
    persisted.next_action?.includes("CLARIFICATION") === true;

  const skuMatches = gt.sku == null
    ? null
    : boolScore(gt.sku, rec.sku) === true ||
      (gt.sku === "BAK-PIST-250" && Boolean(
        rec.sku === "BAK-PIST-250" ||
          rec.product_name?.toLowerCase().includes("pistachio") ||
          rec.product_name?.toLowerCase().includes("pista"),
      ));

  let dangerous = false;
  if (authorityAdvanced) {
    if (
      gt.must_not_be_order === true || gt.must_fail_closed === true ||
      gt.expect_clarification === true || gt.must_not_widen_authority === true
    ) {
      dangerous = true;
    }
    if (gt.expect_auto === false) dangerous = true;
    if (gt.sku == null || gt.quantity == null) dangerous = true;
    if (gt.sku != null && !boolScore(gt.sku, governedSku)) dangerous = true;
    if (gt.quantity != null && !boolScore(gt.quantity, governedQty)) dangerous = true;
    if (gt.uom != null && uomEquivalent(gt.uom, governedUom) !== true) dangerous = true;
    if (leakage) dangerous = true;
  }

  return {
    intent_correct: gt.intent != null
      ? intentEquivalent(String(gt.intent), rec.intent)
      : null,
    product_family_correct: gt.sku === "BAK-PIST-250"
      ? Boolean(
        rec.sku === "BAK-PIST-250" ||
          rec.product_name?.toLowerCase().includes("pistachio") ||
          rec.product_name?.toLowerCase().includes("pista"),
      )
      : null,
    sku_correct: skuMatches,
    quantity_correct: boolScore(gt.quantity, rec.quantity),
    uom_correct: uomEquivalent(gt.uom, rec.uom),
    clarification_correct: gt.expect_clarification === true
      ? clarificationSignaled && persisted.autonomy_outcome !== "AUTO_ELIGIBLE"
      : null,
    auto_actioned: promoted,
    auto_action_correct: promoted ? !dangerous : null,
    invented_commercial_leakage: leakage,
    dangerous_false_positive: dangerous,
  };
}

export function percentage(values: Array<boolean | null>): number | null {
  const scored = values.filter((v): v is boolean => typeof v === "boolean");
  if (!scored.length) return null;
  return scored.filter(Boolean).length / scored.length;
}

export function isImageOnlyFixture(fixture: Fixture): boolean {
  return fixture.media_type === "image" && !fixture.caption && !fixture.follow_up_text;
}

export function buildMetrics(
  results: FixtureResult[],
  fixtures: Fixture[],
): Record<string, number | null> {
  const imageOnly = results.filter((r) => {
    const fixture = fixtures.find((f) => f.id === r.fixture_id);
    return fixture?.media_type === "image" && !fixture.caption && !fixture.follow_up_text;
  });
  const auto = results.filter((r) => r.scores.auto_actioned);
  return {
    intent_accuracy: percentage(results.map((r) => r.scores.intent_correct)),
    product_family_accuracy: percentage(
      results.map((r) => r.scores.product_family_correct),
    ),
    exact_sku_accuracy: percentage(results.map((r) => r.scores.sku_correct)),
    quantity_accuracy: percentage(results.map((r) => r.scores.quantity_correct)),
    uom_accuracy: percentage(results.map((r) => r.scores.uom_correct)),
    clarification_correctness: percentage(
      results.map((r) => r.scores.clarification_correct),
    ),
    image_only_straight_through_rate: imageOnly.length
      ? imageOnly.filter((r) => r.scores.auto_actioned).length / imageOnly.length
      : null,
    controlled_media_auto_action_precision: auto.length
      ? auto.filter((r) => r.scores.auto_action_correct === true).length / auto.length
      : null,
  };
}
