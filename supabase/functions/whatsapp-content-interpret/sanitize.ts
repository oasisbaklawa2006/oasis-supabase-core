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

const PROMPT_INJECTION_PATTERN = /\b(?:IGNORE\s+(?:ALL|PREVIOUS|PRIOR)\s+(?:RULES|INSTRUCTIONS)|AUTO\s*CREATE\s*ORDER|SYSTEM\s+PROMPT|BYPASS\s+(?:RULES|POLICY|CONTROLS?))\b/i;
const CATALOGUE_PATTERN = /\bCATALOG(?:UE)?\b/i;
const EXPLICIT_ORDER_DIRECTIVE_PATTERN = /\b(?:ORDER|SEND|SHIP|NEED|REQUIRE|WANT|BOOK)\s+\d+(?:\.\d+)?\b/i;

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

/** Ensures every evidence id is present in the governed allowlist. */
const validateEvidenceIds = (
  ids: string[],
  allowedIds: Set<string>,
): string[] => {
  for (const id of ids) {
    if (!allowedIds.has(id)) throw new Error("INTERPRETER_INVALID_PROVENANCE");
  }
  return ids;
};

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
): ExplicitFact | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const providerMessageId = safeString(obj.provider_message_id, 240);
  const kind = safeString(obj.kind, 80);
  const factValue = safeString(obj.value, 600);
  if (!providerMessageId || !kind || !factValue) return null;
  validateEvidenceIds([providerMessageId], allowedIds);
  return { provider_message_id: providerMessageId, kind, value: factValue };
};

/** Sanitizes explicit facts with provenance validation. */
const sanitizeExplicitFacts = (
  value: unknown,
  allowedIds: Set<string>,
): ExplicitFact[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 50)
    .map((entry) => parseExplicitFact(entry, allowedIds))
    .filter((fact): fact is ExplicitFact => fact !== null);
};

// skipcq: JS-R1005
const parseOrderLine = (
  entry: unknown,
  allowedIds: Set<string>,
): OrderLine | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const productName = safeString(obj.product_name, 240);
  const sku = safeString(obj.sku, 120);
  if (!productName && !sku) return null;
  const quantityRaw = obj.quantity;
  const quantity =
    typeof quantityRaw === "number" && Number.isFinite(quantityRaw) &&
      quantityRaw > 0
      ? quantityRaw
      : null;
  const unit = safeString(obj.unit, 80);
  const rawStatus = safeString(obj.status, 32).toLowerCase();
  const status: OrderLine["status"] =
    rawStatus === "explicit" || rawStatus === "interpreted"
      ? rawStatus
      : "unclear";
  const evidenceIds = validateEvidenceIds(
    sanitizeStringArray(obj.evidence_ids, 16, 240),
    allowedIds,
  );
  if (status === "explicit" && evidenceIds.length === 0) {
    throw new Error("INTERPRETER_INVALID_PROVENANCE");
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
): OrderLine[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 50)
    .map((entry) => parseOrderLine(entry, allowedIds))
    .filter((line): line is OrderLine => line !== null);
};

// skipcq: JS-R1005
const parseCorrection = (
  entry: unknown,
  allowedIds: Set<string>,
): Correction | null => {
  const obj = entry && typeof entry === "object"
    ? entry as Record<string, unknown>
    : null;
  if (!obj) return null;
  const providerMessageId = safeString(obj.provider_message_id, 240);
  const supersedes = safeString(obj.supersedes, 500);
  const replacement = safeString(obj.replacement, 500);
  if (!providerMessageId || !replacement) return null;
  validateEvidenceIds([providerMessageId], allowedIds);
  return { provider_message_id: providerMessageId, supersedes, replacement };
};

/** Sanitizes explicit corrections with provenance validation. */
const sanitizeCorrections = (
  value: unknown,
  allowedIds: Set<string>,
): Correction[] => {
  if (!Array.isArray(value)) return [];
  return value
    .slice(0, 25)
    .map((entry) => parseCorrection(entry, allowedIds))
    .filter((correction): correction is Correction => correction !== null);
};

/** Sanitizes the nested conclusion object. */
const sanitizeConclusion = (
  value: unknown,
  allowedIds: Set<string>,
): AiConclusion => {
  const obj = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  return {
    intent: sanitizeIntent(obj.intent),
    summary: safeString(obj.summary, 2200),
    explicit_facts: sanitizeExplicitFacts(obj.explicit_facts, allowedIds),
    order_lines: sanitizeOrderLines(obj.order_lines, allowedIds),
    corrections: sanitizeCorrections(obj.corrections, allowedIds),
    ambiguities: sanitizeStringArray(obj.ambiguities, 25, 500),
    recommended_action: safeString(obj.recommended_action, 1800),
    human_review_required: obj.human_review_required !== false,
  };
};

/**
 * Applies deterministic, authority-neutral intent semantics after model parsing.
 * This only narrows case classification; it never supplies missing commercial facts
 * and it never changes human-review or execution authority.
 */
export const normalizeGovernedIntent = (
  intent: ConclusionIntent,
  normalizedText: string,
  extractedText: string,
  conclusion: Pick<AiConclusion, "corrections" | "order_lines">,
): ConclusionIntent => {
  const evidence = `${normalizedText}\n${extractedText}`.trim();

  // Prompt-injection/control-override text is evidence, never executable business intent.
  if (
    (intent === "UNCLEAR" || intent === "OTHER") &&
    PROMPT_INJECTION_PATTERN.test(evidence)
  ) {
    return "OTHER";
  }

  // A later explicit correction to an order packet is an amendment, not a new order.
  if (
    (intent === "NEW_ORDER" || intent === "AMENDMENT") &&
    conclusion.corrections.some((correction) =>
      Boolean(correction.provider_message_id && correction.replacement)
    )
  ) {
    return "AMENDMENT";
  }

  // A catalogue/product-list reference without an explicit order directive or quantity
  // is an enquiry case. It must not be promoted into an order.
  const hasQuantity = conclusion.order_lines.some((line) => line.quantity !== null);
  if (
    (intent === "UNCLEAR" || intent === "ENQUIRY") &&
    CATALOGUE_PATTERN.test(evidence) &&
    !hasQuantity &&
    !EXPLICIT_ORDER_DIRECTIVE_PATTERN.test(evidence)
  ) {
    return "ENQUIRY";
  }

  return intent;
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
  const conclusion = sanitizeConclusion(obj.conclusion, allowedIds);
  const normalizedText = safeString(obj.normalized_text, 12000);
  const extractedText = safeString(obj.extracted_text, 12000);
  conclusion.intent = normalizeGovernedIntent(
    conclusion.intent,
    normalizedText,
    extractedText,
    conclusion,
  );
  if (infrastructureWarnings.length > 0) {
    conclusion.human_review_required = true;
  }
  const confidenceRaw = Number(obj.confidence);
  const confidence = Number.isFinite(confidenceRaw)
    ? Math.max(0, Math.min(1, confidenceRaw))
    : 0;
  return {
    normalized_text: normalizedText,
    extracted_text: extractedText,
    language: safeString(obj.language, 120) || "unknown",
    confidence,
    warnings: [
      ...new Set([
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
