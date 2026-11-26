// APPVERSE-CORE-AI-BUDGET-01: fail-closed budget orchestration for the Studio AI-copy provider call.
//
// Order of operations (every step fails closed; nothing reaches the paid inference call otherwise):
//   authenticated staff (caller) -> rate-limit gate -> serialized byte ceiling -> official input-token
//   count -> atomic monetary reservation -> ONE inference call -> settlement from verified usage.
//
// This module performs no network I/O itself: the provider calls are injected so the ordering and the
// fail-closed behaviour are testable offline. No retry, no model fallback, no premium tier.

/** The only model the policy approves. A different configured or returned model is a violation. */
export const APPROVED_MODEL = "gpt-5.4-mini-2026-03-17";
export const MAX_INPUT_TOKENS = 8000;
export const MAX_OUTPUT_TOKENS = 1400;
/** Defensive pre-filter on the serialized inference body; the official count is the authority. */
export const MAX_BODY_BYTES = 8000;
export const COUNT_TIMEOUT_MS = 10_000;
export const INFERENCE_TIMEOUT_MS = 20_000;

export interface ProviderRequests {
  /** Exactly the fields the official counting endpoint accepts and inference also sends. */
  countBody: Record<string, unknown>;
  inferenceBody: Record<string, unknown>;
}

/**
 * The count request carries the same model, input and structured-output schema as inference, plus the
 * same reasoning setting. Inference adds only the standard-tier pin and the output ceiling.
 */
export function buildProviderRequests(
  systemPrompt: string,
  userPrompt: string,
  schema: unknown,
): ProviderRequests {
  const countBody: Record<string, unknown> = {
    model: APPROVED_MODEL,
    input: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    text: {
      format: {
        type: "json_schema",
        name: "catalogue_copy",
        strict: true,
        schema,
      },
    },
    reasoning: { effort: "none" },
  };
  const inferenceBody: Record<string, unknown> = {
    ...countBody,
    service_tier: "default",
    max_output_tokens: MAX_OUTPUT_TOKENS,
  };
  return { countBody, inferenceBody };
}

export interface Settlement {
  status?: string;
  violation?: string | null;
}

/** Server-only accounting (service_role RPCs). Any throw is treated as "accounting unavailable". */
export interface Accounting {
  gate(actorId: string, model: string): Promise<string | null>;
  reserve(
    reservationId: string,
    actorId: string,
    model: string,
    countedInputTokens: number,
  ): Promise<boolean>;
  settle(
    reservationId: string,
    inputTokens: number,
    outputTokens: number,
    providerRequestId: string | null,
    responseModel: string | null,
    responseServiceTier: string | null,
  ): Promise<Settlement>;
  markAmbiguous(reservationId: string): Promise<void>;
  /** Sets the emergency latch (service_role RPC). Best-effort here; the full reservation stays held. */
  emergencyDisable(reason: string): Promise<void>;
}

export interface ProviderReply {
  status: number;
  body: unknown;
  requestId: string | null;
}

export interface BudgetedDeps {
  actorId: string;
  requests: ProviderRequests;
  accounting: Accounting;
  countTokens(body: Record<string, unknown>): Promise<ProviderReply>;
  infer(body: Record<string, unknown>): Promise<ProviderReply>;
}

export type BudgetedResult =
  | { ok: true; body: unknown; requestId: string | null }
  | { ok: false; status: number; error: string; stage: string };

function fail(status: number, error: string, stage: string): BudgetedResult {
  return { ok: false, status, error, stage };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

export function serializedByteLength(body: unknown): number {
  return new TextEncoder().encode(JSON.stringify(body)).length;
}

async function markAmbiguousBestEffort(
  accounting: Accounting,
  reservationId: string,
): Promise<void> {
  try {
    await accounting.markAmbiguous(reservationId);
  } catch {
    // The reservation stays 'reserved' (the full amount remains charged): conservative either way.
  }
}

/** Latch on a model/tier mismatch even when usage is unverifiable (mirrors the settle RPC's test). */
async function latchOnMismatchBestEffort(
  accounting: Accounting,
  reply: ProviderReply,
  body: Record<string, unknown> | null,
): Promise<void> {
  if (reply.status < 200 || reply.status >= 300 || !body) return;
  const reason = body.model !== APPROVED_MODEL
    ? "auto:model_mismatch_unverifiable"
    : body.service_tier !== "default"
    ? "auto:tier_mismatch_unverifiable"
    : null;
  if (!reason) return;
  try {
    await accounting.emergencyDisable(reason);
  } catch {
    // Best-effort: the reservation is still held in full; the manual latch and kill switch remain.
  }
}

export async function runBudgetedInference(
  deps: BudgetedDeps,
): Promise<BudgetedResult> {
  const { accounting, actorId, requests } = deps;
  if (requests.inferenceBody.model !== APPROVED_MODEL) {
    return fail(503, "AI service is not configured", "model");
  }

  // 1. Rate-limit gate BEFORE any provider call (including the free count).
  let reservationId: string | null;
  try {
    reservationId = await accounting.gate(actorId, APPROVED_MODEL);
  } catch {
    return fail(503, "AI budget accounting unavailable", "gate");
  }
  if (!reservationId) return fail(429, "AI usage limit reached", "gate");

  // 2. Defensive serialized-size ceiling.
  if (serializedByteLength(requests.inferenceBody) > MAX_BODY_BYTES) {
    return fail(413, "request too large", "byte_ceiling");
  }

  // 3. Official pre-inference token count of the SAME payload. Any doubt fails closed.
  let counted: number;
  try {
    const reply = await deps.countTokens(requests.countBody);
    const body = asRecord(reply.body);
    const tokens = body?.input_tokens;
    if (reply.status !== 200 || !body || !isCount(tokens) || tokens < 1) {
      return fail(503, "AI service unavailable", "count");
    }
    counted = tokens;
  } catch {
    return fail(503, "AI service unavailable", "count");
  }
  if (counted > MAX_INPUT_TOKENS) {
    return fail(413, "request too large", "count");
  }

  // 4. Atomic monetary reservation (all user and company limits in one transaction).
  try {
    const reserved = await accounting.reserve(
      reservationId,
      actorId,
      APPROVED_MODEL,
      counted,
    );
    if (reserved !== true) {
      return fail(429, "AI usage limit reached", "reserve");
    }
  } catch {
    return fail(503, "AI budget accounting unavailable", "reserve");
  }

  // 5. ONE inference call. No retry, no fallback. Anything unclear keeps the full reservation.
  let reply: ProviderReply;
  try {
    reply = await deps.infer(requests.inferenceBody);
  } catch {
    await markAmbiguousBestEffort(accounting, reservationId);
    return fail(502, "AI provider request failed", "inference");
  }
  const body = asRecord(reply.body);
  const usage = asRecord(body?.usage);
  const inputTokens = usage?.input_tokens;
  const outputTokens = usage?.output_tokens;
  if (
    reply.status < 200 || reply.status >= 300 || !body ||
    !isCount(inputTokens) || !isCount(outputTokens)
  ) {
    await latchOnMismatchBestEffort(accounting, reply, body);
    await markAmbiguousBestEffort(accounting, reservationId);
    return fail(502, "AI provider request failed", "inference");
  }

  // 6. Settlement from verified usage (idempotent in the database).
  let settlement: Settlement;
  try {
    settlement = await accounting.settle(
      reservationId,
      inputTokens,
      outputTokens,
      reply.requestId,
      typeof body.model === "string" ? body.model : null,
      typeof body.service_tier === "string" ? body.service_tier : null,
    );
  } catch {
    // Cannot confirm the charge: the reservation stays held in full and the content is withheld.
    return fail(503, "AI budget accounting unavailable", "settle");
  }
  if (settlement.violation) {
    return fail(502, "AI provider contract violation", "settle");
  }
  if (settlement.status !== "settled") {
    return fail(502, "AI provider request failed", "settle");
  }
  return { ok: true, body: reply.body, requestId: reply.requestId };
}
