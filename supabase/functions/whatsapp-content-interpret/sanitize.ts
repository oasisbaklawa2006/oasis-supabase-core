/** @file Strict sanitization for WhatsApp B2B multimodal interpreter JSON output. */

import type { SourceKind } from "./types.ts";

export type ConclusionIntent =
  | "NEW_ORDER"
  | "AMENDMENT"
  | "ENQUIRY"
  | "COMPLAINT"
  | "FINANCE"
  | "OTHER"
  | "UNCLEAR";

export type ExplicitFact = {
  provider_message_id: string;
  kind: string;
  value: string;
};

export type OrderLine = {
  product_name: string;
  sku: string;
  quantity: number | null;
  unit: string;
  status: "explicit" | "interpreted" | "unclear";
  evidence_ids: string[];
};

export type Correction = {
  provider_message_id: string;
  supersedes: string;
  replacement: string;
};

export type AiConclusion = {
  intent: ConclusionIntent;
  summary: string;
  explicit_facts: ExplicitFact[];
  order_lines: OrderLine[];
  corrections: Correction[];
  ambiguities: string[];
  recommended_action: string;
  human_review_required: boolean;
};

export type InterpretResponse = {
  normalized_text: string;
  extracted_text: string;
  language: string;
  confidence: number;
  warnings: string[];
  source_kind: SourceKind;
  conclusion: AiConclusion;
};

const ALLOWED_INTENTS: ConclusionIntent[] = [
  "NEW_ORDER",
  "AMENDMENT",
  "ENQUIRY",
  "COMPLAINT",
  "FINANCE",
  "OTHER",
  "UNCLEAR",
];

/** Returns a bounded trimmed string when the value is textual. */
const safeString = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

/** Sanitizes an array of bounded strings. */
const sanitizeStringArray = (
  value: unknown,
  maxItems: number,
  maxLength: number,
): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim().slice(0, maxLength))
    .filter(Boolean)
    .slice(0, maxItems);
};

/**
 * Splits evidence ids into those present in the governed allowlist and those
 * that are not. Unknown ids are never kept, repaired or replaced: provenance
 * is only ever what the packet actually contains.
 */
const partitionEvidenceIds = (
  ids: string[],
  allowedIds: Set<string>,
): { valid: string[]; rejected: string[] } => ({
  valid: ids.filter((id) => allowedIds.has(id)),
  rejected: ids.filter((id) => !allowedIds.has(id)),
});

/** Bounded, human-readable record of an item the sanitizer isolated. */
const isolationNote = (kind: string, index: number, detail: string): string =>
  `PROVENANCE_ISOLATED:${kind}_${index + 1}:${detail}`.slice(0, 320);

/** Normalizes model intent into the governed intent enum. */
const sanitizeIntent = (value: unknown): ConclusionIntent => {
  const candidate = safeString(value, 32).toUpperCase();
  return ALLOWED_INTENTS.includes(candidate as ConclusionIntent)
    ? candidate as ConclusionIntent
    : "UNCLEAR";
};

// skipcq: JS-R1005
const parseExplicitFact = (
  entry: unknown,
  allowedIds: Set<string>,
  index: number,
  isolated: string[],
): ExplicitFact | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const providerMessageId = safeString(obj.provider_message_id, 240);
  const kind = safeString(obj.kind, 80);
  const factValue = safeString(obj.value, 600);
  if (!providerMessageId || !kind || !factValue) return null;
  if (!allowedIds.has(providerMessageId)) {
    isolated.push(
      isolationNote("explicit_fact", index, `${kind}=${factValue}`),
    );
    return null;
  }
  return { provider_message_id: providerMessageId, kind, value: factValue };
};

/** Sanitizes explicit facts with provenance validation. */
const sanitizeExplicitFacts = (
  value: unknown,
  allowedIds: Set<string>,
  isolated: string[],
): ExplicitFact[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 50)
    .map((entry, index) =>
      parseExplicitFact(entry, allowedIds, index, isolated)
    )
    .filter((fact): fact is ExplicitFact => fact !== null);
};

// skipcq: JS-R1005
const parseOrderLine = (
  entry: unknown,
  allowedIds: Set<string>,
  index: number,
  isolated: string[],
): OrderLine | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const productName = safeString(obj.product_name, 240);
  const sku = safeString(obj.sku, 120);
  const quantityRaw = obj.quantity;
  const quantity =
    typeof quantityRaw === "number" && Number.isFinite(quantityRaw) &&
      quantityRaw > 0
      ? quantityRaw
      : null;
  // A quantity with no named product is still evidence ("send 75 boxes"); it is
  // kept as an unresolved line instead of being silently discarded.
  if (!productName && !sku && quantity === null) return null;
  const unit = safeString(obj.unit, 80);
  const rawStatus = safeString(obj.status, 32).toLowerCase();
  let status: OrderLine["status"] =
    rawStatus === "explicit" || rawStatus === "interpreted"
      ? rawStatus
      : "unclear";
  const { valid: evidenceIds, rejected } = partitionEvidenceIds(
    sanitizeStringArray(obj.evidence_ids, 16, 240),
    allowedIds,
  );
  // A line whose provenance cannot be proven is kept for the human reviewer
  // but can never stay "explicit"; it is downgraded, never repaired.
  if (
    rejected.length > 0 || (status === "explicit" && evidenceIds.length === 0)
  ) {
    status = "unclear";
    isolated.push(
      isolationNote(
        "order_line",
        index,
        `${productName || sku} qty=${quantity ?? "?"}${unit ? ` ${unit}` : ""}`,
      ),
    );
  }
  return {
    product_name: productName,
    sku,
    quantity,
    unit,
    status,
    evidence_ids: evidenceIds,
  };
};

/** Sanitizes order lines with provenance validation. */
const sanitizeOrderLines = (
  value: unknown,
  allowedIds: Set<string>,
  isolated: string[],
): OrderLine[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 50)
    .map((entry, index) => parseOrderLine(entry, allowedIds, index, isolated))
    .filter((line): line is OrderLine => line !== null);
};

// skipcq: JS-R1005
const parseCorrection = (
  entry: unknown,
  allowedIds: Set<string>,
  index: number,
  isolated: string[],
): Correction | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const providerMessageId = safeString(obj.provider_message_id, 240);
  const supersedes = safeString(obj.supersedes, 500);
  const replacement = safeString(obj.replacement, 500);
  if (!providerMessageId || !replacement) return null;
  if (!allowedIds.has(providerMessageId)) {
    isolated.push(
      isolationNote("correction", index, `${supersedes} -> ${replacement}`),
    );
    return null;
  }
  return { provider_message_id: providerMessageId, supersedes, replacement };
};

/** Sanitizes explicit corrections with provenance validation. */
const sanitizeCorrections = (
  value: unknown,
  allowedIds: Set<string>,
  isolated: string[],
): Correction[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 25)
    .map((entry, index) => parseCorrection(entry, allowedIds, index, isolated))
    .filter((correction): correction is Correction => correction !== null);
};

/** Sanitizes the nested conclusion object. */
const sanitizeConclusion = (
  value: unknown,
  allowedIds: Set<string>,
  isolated: string[],
): AiConclusion => {
  const obj = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  return {
    intent: sanitizeIntent(obj.intent),
    summary: safeString(obj.summary, 2200),
    explicit_facts: sanitizeExplicitFacts(
      obj.explicit_facts,
      allowedIds,
      isolated,
    ),
    order_lines: sanitizeOrderLines(obj.order_lines, allowedIds, isolated),
    corrections: sanitizeCorrections(obj.corrections, allowedIds, isolated),
    ambiguities: sanitizeStringArray(obj.ambiguities, 25, 500),
    recommended_action: safeString(obj.recommended_action, 1800),
    human_review_required: obj.human_review_required !== false,
  };
};

/** Sanitizes interpreter JSON into the governed response contract. skipcq: JS-R1005 */
export const sanitizeInterpretResult = (
  raw: unknown,
  sourceKind: SourceKind,
  infrastructureWarnings: string[],
  allowedIds: Set<string>,
): InterpretResponse => {
  const obj = raw && typeof raw === "object"
    ? raw as Record<string, unknown>
    : {};
  const isolated: string[] = [];
  const conclusion = sanitizeConclusion(obj.conclusion, allowedIds, isolated);
  if (infrastructureWarnings.length > 0 || isolated.length > 0) {
    conclusion.human_review_required = true;
  }
  const confidenceRaw = Number(obj.confidence);
  const confidence = Number.isFinite(confidenceRaw)
    ? Math.max(0, Math.min(1, confidenceRaw))
    : 0;
  return {
    normalized_text: safeString(obj.normalized_text, 12000),
    extracted_text: safeString(obj.extracted_text, 12000),
    language: safeString(obj.language, 120) || "unknown",
    confidence,
    warnings: [
      ...new Set([
        ...isolated,
        ...sanitizeStringArray(obj.warnings, 20, 320),
        ...infrastructureWarnings.map((warning) => warning.slice(0, 320)),
      ]),
    ].slice(0, 24),
    source_kind: sourceKind,
    conclusion,
  };
};

const EXACT_ERROR_STATUS = new Map<string, number>([
  ["INTERPRETER_NOT_CONFIGURED", 503],
  ["INTERPRETER_PROVIDER_RATE_LIMITED", 429],
  ["INTERPRETER_PROVIDER_CREDITS_EXHAUSTED", 503],
  ["INTERPRETER_PROVIDER_AUTH_FAILED", 502],
  ["INTERPRETER_INVALID_PROVENANCE", 502],
  ["EMPTY_MEDIA", 422],
  ["AUDIO_TRANSCRIPTION_EMPTY", 422],
  ["MEDIA_TOO_LARGE", 413],
  ["PACKET_MEDIA_TOO_LARGE", 413],
  ["MEDIA_HOST_NOT_ALLOWED", 422],
  ["MEDIA_REDIRECT_NOT_ALLOWED", 422],
]);

const UNSUPPORTED_MIME_CODES = new Set([
  "UNSUPPORTED_IMAGE_TYPE",
  "UNSUPPORTED_AUDIO_TYPE",
  "UNSUPPORTED_VIDEO_TYPE",
  "UNSUPPORTED_DOCUMENT_TYPE",
]);

const MEDIA_URL_PREFIX_CODES = [
  "MEDIA_URL_INVALID",
  "MEDIA_URL_PROTOCOL_NOT_ALLOWED",
  "MEDIA_URL_CREDENTIALS_NOT_ALLOWED",
];

/** Maps interpreter failure codes to HTTP status without widening authority. */
export const statusForInterpretationError = (code: string): number => {
  const exactStatus = EXACT_ERROR_STATUS.get(code);
  if (exactStatus !== undefined) return exactStatus;
  if (UNSUPPORTED_MIME_CODES.has(code)) return 415;
  if (MEDIA_URL_PREFIX_CODES.includes(code) || code.startsWith("MEDIA_URL_")) {
    return 422;
  }
  return 502;
};
