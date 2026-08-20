import type { SupabaseClient } from "@supabase/supabase-js";

export type WhatsAppCommercialLayers = {
  caseId: string;
  requestedLines: Record<string, unknown>[];
  interpretations: Record<string, unknown>[];
  proposedChanges: Record<string, unknown>[];
  confirmations: Record<string, unknown>[];
  handoffs: Record<string, unknown>[];
  paymentProofs: Record<string, unknown>[];
};

type RpcResult = { data: unknown; error: { message?: string } | null };
type RpcInvoker = (name: string, args?: Record<string, unknown>) => PromiseLike<RpcResult>;

const rpcInvoker = (supabase: SupabaseClient): RpcInvoker =>
  supabase.rpc.bind(supabase) as unknown as RpcInvoker;

function record(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.map(record).filter((item): item is Record<string, unknown> => item !== null)
    : [];
}

function required(value: string, code: string, max = 4000): string {
  const normalized = value.trim();
  if (!normalized || normalized.length > max) throw new Error(code);
  return normalized;
}

async function rpcRecord(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const { data, error } = await rpcInvoker(supabase)(name, args);
  if (error) throw new Error(error.message || `${name.toUpperCase()}_FAILED`);
  const result = record(data) ?? record(Array.isArray(data) ? data[0] : null);
  if (!result) throw new Error(`${name.toUpperCase()}_SHAPE_UNEXPECTED`);
  return result;
}

export async function fetchWhatsAppCommercialLayers(
  supabase: SupabaseClient,
  caseId: string,
): Promise<WhatsAppCommercialLayers> {
  const root = await rpcRecord(supabase, "whatsapp_get_case_commercial_layers", { p_case_id: caseId });
  return {
    caseId,
    requestedLines: records(root.requested_lines),
    interpretations: records(root.interpretations),
    proposedChanges: records(root.proposed_changes),
    confirmations: records(root.confirmations),
    handoffs: records(root.handoffs),
    paymentProofs: records(root.payment_proofs),
  };
}

export async function confirmWhatsAppOriginalCommunicator(
  supabase: SupabaseClient,
  input: {
    caseId: string;
    partyType: "EMPLOYEE" | "CUSTOMER" | "CONTACT" | "COMPANY" | "UNKNOWN";
    partyId?: string | null;
    displayLabel: string;
    phoneE164?: string | null;
    verificationMethod: "DIRECT_MESSAGE" | "FORWARDED_MESSAGE" | "CALLBACK" | "EMPLOYEE_REPORT" | "CUSTOMER_NOMINATED" | "OPERATOR_VERIFIED";
    evidence: Record<string, unknown>;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_confirm_original_communicator", {
    p_case_id: input.caseId,
    p_party_type: input.partyType,
    p_party_id: input.partyType === "UNKNOWN" ? null : input.partyId || null,
    p_display_label: required(input.displayLabel, "ORIGINAL_COMMUNICATOR_LABEL_REQUIRED", 300),
    p_phone_e164: input.phoneE164?.trim() || null,
    p_verification_method: input.verificationMethod,
    p_evidence: input.evidence,
    p_idempotency_key: required(input.idempotencyKey, "ORIGINAL_COMMUNICATOR_KEY_REQUIRED", 160),
  });
}

export async function proposeWhatsAppCaseChange(
  supabase: SupabaseClient,
  input: {
    caseId: string;
    interpretationId?: string | null;
    changeType: string;
    requestedValue: unknown;
    proposedValue: unknown;
    reason: string;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_propose_case_change", {
    p_case_id: input.caseId,
    p_interpretation_id: input.interpretationId || null,
    p_change_type: required(input.changeType, "PROPOSED_CHANGE_TYPE_REQUIRED", 80).toUpperCase(),
    p_requested_value: input.requestedValue ?? null,
    p_proposed_value: input.proposedValue,
    p_reason: required(input.reason, "PROPOSED_CHANGE_REASON_REQUIRED", 1000),
    p_idempotency_key: required(input.idempotencyKey, "PROPOSED_CHANGE_KEY_REQUIRED", 160),
  });
}

export async function decideWhatsAppCaseProposedChange(
  supabase: SupabaseClient,
  input: {
    changeId: string;
    decision: "OPERATOR_APPROVED" | "CUSTOMER_APPROVED" | "REJECTED";
    sourceMessageId?: string | null;
    authorityReference?: string | null;
    reason: string;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_decide_case_proposed_change", {
    p_change_id: input.changeId,
    p_decision: input.decision,
    p_source_message_id: input.sourceMessageId || null,
    p_authority_reference: input.authorityReference?.trim() || null,
    p_reason: required(input.reason, "PROPOSED_CHANGE_DECISION_REASON_REQUIRED", 1000),
    p_idempotency_key: required(input.idempotencyKey, "PROPOSED_CHANGE_DECISION_KEY_REQUIRED", 160),
  });
}

export async function acceptWhatsAppCaseHandoff(
  supabase: SupabaseClient,
  input: {
    caseId: string;
    toTeam: string;
    reason: string;
    openWorkSnapshot: Record<string, unknown>;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_accept_case_handoff", {
    p_case_id: input.caseId,
    p_to_team: required(input.toTeam, "HANDOFF_TEAM_REQUIRED", 80).toUpperCase(),
    p_reason: required(input.reason, "HANDOFF_REASON_REQUIRED", 1000),
    p_open_work_snapshot: input.openWorkSnapshot,
    p_idempotency_key: required(input.idempotencyKey, "HANDOFF_KEY_REQUIRED", 160),
  });
}

export async function releaseReviewedWhatsAppCaseReply(
  supabase: SupabaseClient,
  input: {
    outboundDecisionId: string;
    evidenceReference: string;
    decisionBasis: string;
    idempotencyKey: string;
  },
): Promise<Record<string, unknown>> {
  return rpcRecord(supabase, "whatsapp_release_reviewed_case_reply", {
    p_outbound_decision_id: input.outboundDecisionId,
    p_evidence: {
      evidence_reference: required(input.evidenceReference, "REVIEW_EVIDENCE_REFERENCE_REQUIRED", 1000),
      decision_basis: required(input.decisionBasis, "REVIEW_DECISION_BASIS_REQUIRED", 2000),
    },
    p_idempotency_key: required(input.idempotencyKey, "REVIEWED_REPLY_KEY_REQUIRED", 160),
  });
}

export function newWhatsAppCaseCommercialActionKey(prefix: string, caseId: string): string {
  const cryptoApi = globalThis.crypto;
  if (typeof cryptoApi?.randomUUID !== "function") {
    throw new Error("SECURE_RANDOM_UNAVAILABLE");
  }
  return `${prefix}:${caseId}:${cryptoApi.randomUUID()}`.slice(0, 160);
}
