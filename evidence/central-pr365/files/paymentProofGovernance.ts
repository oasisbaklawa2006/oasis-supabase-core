import type { SupabaseClient } from "@supabase/supabase-js";

type RpcResult = { data: unknown; error: { message?: string } | null };
type RpcInvoker = (name: string, args?: Record<string, unknown>) => PromiseLike<RpcResult>;

const invoke = (supabase: SupabaseClient): RpcInvoker =>
  supabase.rpc.bind(supabase) as unknown as RpcInvoker;

function record(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

async function rpcRecord(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const { data, error } = await invoke(supabase)(name, args);
  if (error) throw new Error(error.message || `${name.toUpperCase()}_FAILED`);
  const result = record(data) ?? record(Array.isArray(data) ? data[0] : null);
  if (!result) throw new Error(`${name.toUpperCase()}_SHAPE_UNEXPECTED`);
  return result;
}

export async function captureWhatsAppPaymentProof(
  supabase: SupabaseClient,
  input: {
    caseId: string;
    sourceMessageId: string;
    claimedAmount?: number | null;
    claimedReference?: string | null;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "capture_whatsapp_payment_proof_evidence", {
    p_case_id: input.caseId,
    p_source_message_id: input.sourceMessageId,
    p_detected_by: "OPERATOR",
    p_claimed_amount: input.claimedAmount ?? null,
    p_claimed_reference: input.claimedReference?.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  });
}

export async function reviewWhatsAppPaymentProof(
  supabase: SupabaseClient,
  input: {
    paymentProofId: string;
    decision: "VERIFIED" | "REJECTED";
    verifiedAmount?: number | null;
    verifiedReference?: string | null;
    reason?: string | null;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_review_case_payment_proof", {
    p_payment_proof_id: input.paymentProofId,
    p_decision: input.decision,
    p_verified_amount: input.decision === "VERIFIED" ? input.verifiedAmount ?? null : null,
    p_verified_reference: input.decision === "VERIFIED" ? input.verifiedReference?.trim() || null : null,
    p_reason: input.decision === "REJECTED" ? input.reason?.trim() || null : null,
    p_idempotency_key: input.idempotencyKey,
  });
}

export function newPaymentProofActionKey(prefix: string, caseId: string): string {
  const cryptoApi = globalThis.crypto;
  if (typeof cryptoApi?.randomUUID !== "function") {
    throw new Error("SECURE_RANDOM_UNAVAILABLE");
  }
  return `${prefix}:${caseId}:${cryptoApi.randomUUID()}`.slice(0, 160);
}
