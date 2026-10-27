/** Governed persistence for authenticated provider delivery-status callbacks. */
export type ProviderStatusEvent = {
  status: string;
  providerMessageId: string | null;
  providerErrorCode?: string | number | null;
};

type QueryResult<T> = { data: T | null; error: { message: string } | null };
type AdminClient = {
  rpc: (fn: string, args: Record<string, unknown>) => any;
  from: (table: string) => { insert: (row: Record<string, unknown>) => unknown };
};
export type ProviderStatusBatchResult = {
  count: number;
  updated: number;
  ignored: number;
  unmatched: number;
  quarantined: number;
};
export type BoundedProviderStatus = "ACCEPTED" | "DELIVERED" | "READ" | "FAILED_FINAL";

const STATUS_RANK: Record<string, number> = {
  QUEUED: 0, SENDING: 1, ACCEPTANCE_UNKNOWN: 1, ACCEPTED: 2, DELIVERED: 3, READ: 4,
};

/** A callback must never erase verified customer delivery. */
export function normalizeOperatorReplyProviderStatus(status: string): BoundedProviderStatus | null {
  switch (status.trim().toLowerCase()) {
    case "sent":
    case "accepted":
      return "ACCEPTED";
    case "delivered":
      return "DELIVERED";
    case "read":
      return "READ";
    case "failed":
    case "undelivered":
      return "FAILED_FINAL";
    default:
      return null;
  }
}

/** FAILED_FINAL is absorbing, but never overrides a verified delivery/read receipt. */
export function shouldAdvanceOperatorReplyStatus(current: string, target: string): boolean {
  const previous = current.toUpperCase();
  const next = target.toUpperCase();
  if (previous === "FAILED_FINAL") return false;
  if (next === "FAILED_FINAL") return previous !== "DELIVERED" && previous !== "READ"
    && Object.hasOwn(STATUS_RANK, previous);
  const currentRank = STATUS_RANK[previous] ?? -1;
  const targetRank = STATUS_RANK[next] ?? -1;
  return targetRank >= 0 && targetRank > currentRank;
}

export async function persistOperatorReplyProviderStatus(
  admin: AdminClient,
  event: ProviderStatusEvent,
): Promise<{ matched: boolean; updated: boolean; status: string | null }> {
  const providerMessageId = event.providerMessageId?.trim() ?? "";
  const targetStatus = normalizeOperatorReplyProviderStatus(event.status);
  if (!targetStatus) return { matched: false, updated: false, status: null };
  // A recognized callback without a correlation ID must be retried, not acknowledged as delivered.
  if (!providerMessageId) throw new Error("WA_STATUS_PROVIDER_ID_MISSING");
  // Do not put arbitrary provider text, phone numbers or raw callbacks into the audit ledger.
  const providerErrorCode = String(event.providerErrorCode ?? "")
    .replace(/[^a-zA-Z0-9_.:-]/g, "").slice(0, 64);
  const rpcResult = await admin.rpc("persist_whatsapp_operator_reply_provider_status", {
    p_provider_message_id: providerMessageId,
    p_status: targetStatus,
    p_evidence: {
      provider_status: event.status.trim().toLowerCase(),
      target_status: targetStatus,
      provider_message_id_present: true,
      ...(targetStatus === "FAILED_FINAL" && providerErrorCode ? { provider_error_code: providerErrorCode } : {}),
    },
  }) as QueryResult<Record<string, unknown>>;
  if (rpcResult.error) throw new Error(`WA_STATUS_RPC_FAILED:${rpcResult.error.message.slice(0, 160)}`);
  const payload = rpcResult.data ?? {};
  return {
    matched: payload.matched === true,
    updated: payload.updated === true,
    status: typeof payload.status === "string" ? payload.status : null,
  };
}

/**
 * Durable correlation for a recognized provider status that does not map to the
 * governed operator-reply outbox. Does not claim delivery on any outbound row.
 */
export async function quarantineUnmatchedOperatorReplyStatus(
  admin: AdminClient,
  event: ProviderStatusEvent,
): Promise<void> {
  const providerMessageId = event.providerMessageId?.trim() ?? "";
  const normalized = normalizeOperatorReplyProviderStatus(event.status);
  if (!normalized || !providerMessageId) {
    throw new Error("WA_STATUS_QUARANTINE_INVALID");
  }
  const insertResult = await admin.from("debug_webhooks").insert({
    direction: "provider_status_unmatched",
    wamid: providerMessageId,
    processed: true,
    discard_reason: "operator_reply_outbox_unmatched",
    error_message: null,
    raw_payload: {
      provider_status: event.status.trim().toLowerCase(),
      target_status: normalized,
      provider_message_id: providerMessageId,
      quarantine: "WA_STATUS_OUTBOX_UNMATCHED",
    },
  }) as { error: { message: string } | null };
  if (insertResult.error) {
    throw new Error(`WA_STATUS_QUARANTINE_FAILED:${insertResult.error.message.slice(0, 160)}`);
  }
}

/**
 * Idempotent batch: retrying after a partial RPC failure safely replays prior members.
 *
 * O2 semantics: a recognized provider status whose ID is not in the governed operator-reply
 * outbox is durably quarantined (`debug_webhooks.direction=provider_status_unmatched`) and
 * counted as `unmatched`/`quarantined`. It does not advance outbox state and does not block
 * later batch members or inbound processing in the webhook handler. Only RPC/quarantine
 * failures remain retryable (503).
 */
export async function persistOperatorReplyProviderStatusBatch(
  admin: AdminClient, events: readonly ProviderStatusEvent[],
): Promise<ProviderStatusBatchResult> {
  let updated = 0;
  let ignored = 0;
  let unmatched = 0;
  let quarantined = 0;
  let retryableFailures = 0;
  // Process every member. A transient failure cannot starve later callbacks:
  // retries are safe because successful members are atomic/idempotent.
  for (const event of events) {
    if (!normalizeOperatorReplyProviderStatus(event.status)) {
      // Meta sends advisory states (e.g. warning/deleted) outside the bounded
      // delivery receipt contract. Ignore them without retry-storming delivery.
      ignored++;
      continue;
    }
    try {
      const outcome = await persistOperatorReplyProviderStatus(admin, event);
      if (!outcome.matched) {
        unmatched++;
        await quarantineUnmatchedOperatorReplyStatus(admin, event);
        quarantined++;
      } else if (outcome.updated) updated++;
    } catch {
      retryableFailures++;
    }
  }
  if (retryableFailures) throw new Error(`WA_STATUS_BATCH_RETRYABLE_FAILURES:${retryableFailures}`);
  return { count: events.length, updated, ignored, unmatched, quarantined };
}
