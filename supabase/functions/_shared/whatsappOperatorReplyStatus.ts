/** Governed persistence for authenticated provider delivery-status callbacks. */
export type ProviderStatusEvent = {
  status: string;
  providerMessageId: string | null;
  providerErrorCode?: string | number | null;
};

type QueryResult<T> = { data: T | null; error: { message: string } | null };
type AdminClient = {
  rpc: (fn: string, args: Record<string, unknown>) => any;
  from: (table: string) => any;
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


/** Stable opaque UUIDv8 for an unmatched status event. Never contains a raw phone or message ID. */
export async function unmatchedStatusAuditUuid(
  providerMessageId: string,
  status: string,
  providerErrorCode?: string | number | null,
): Promise<string> {
  const boundedError = String(providerErrorCode ?? "").replace(/[^a-zA-Z0-9_.:-]/g, "").slice(0, 64);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify([
      "oasis/wa450/unmatched-status/v1", providerMessageId.trim(), status, boundedError,
    ])),
  );
  const bytes = new Uint8Array(digest).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const value = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return [value.slice(0, 8), value.slice(8, 12), value.slice(12, 16),
    value.slice(16, 20), value.slice(20)].join("-");
}

/** Reconcile pending receipts after their governed provider IDs reach the outbox.
 * No customer sends, retries, or outbound queue mutations occur here.
 * Unknown IDs remain operator-visible and pending, never falsely marked delivered.
 */
export async function reconcileUnmatchedOperatorReplyStatuses(
  admin: AdminClient,
  maxEvents = 10,
): Promise<{ checked: number; recovered: number; pending: number; errors: number }> {
  const limit = Number.isInteger(maxEvents) ? Math.max(1, Math.min(maxEvents, 20)) : 10;
  // Persist a cursor independent of unlinked receipts. Always scan a different
  // UUID range on the next worker tick, even when an older receipt never links.
  const cursorId = "00000000-0000-8000-8000-000000000450";
  const { data: cursorRow, error: cursorReadError } = await admin.from("debug_webhooks")
    .select("raw_payload").eq("id", cursorId).maybeSingle() as QueryResult<Record<string, unknown>>;
  if (cursorReadError) throw new Error("WA_STATUS_RECONCILE_CURSOR_READ_FAILED");
  const cursorPayload = cursorRow?.raw_payload && typeof cursorRow.raw_payload === "object"
    ? cursorRow.raw_payload as Record<string, unknown> : {};
  const lastId = typeof cursorPayload.last_scanned_id === "string"
    ? cursorPayload.last_scanned_id : "";

  const nextPage = (afterId: string) => {
    let query = admin.from("debug_webhooks")
      .select("id,wamid,raw_payload")
      .eq("direction", "provider_status_unmatched")
      .eq("processed", false);
    if (afterId) query = query.gt("id", afterId);
    return query.order("id", { ascending: true }).limit(limit) as PromiseLike<
      QueryResult<Record<string, unknown>[]>
    >;
  };
  let { data, error } = await nextPage(lastId);
  if (error) throw new Error("WA_STATUS_RECONCILE_READ_FAILED");
  // Wrap after the greatest pending key; newly arrived older keys are
  // considered on the next cycle rather than starved by permanent orphans.
  if ((!data || data.length === 0) && lastId) {
    ({ data, error } = await nextPage(""));
    if (error) throw new Error("WA_STATUS_RECONCILE_WRAP_READ_FAILED");
  }
  let recovered = 0;
  let pending = 0;
  let errors = 0;
  for (const row of data ?? []) {
    const id = typeof row.id === "string" ? row.id : "";
    const raw = row.raw_payload && typeof row.raw_payload === "object"
      ? row.raw_payload as Record<string, unknown> : {};
    const providerMessageId = typeof row.wamid === "string" ? row.wamid : "";
    const status = typeof raw.provider_status === "string" ? raw.provider_status : "";
    if (!id || !providerMessageId || !normalizeOperatorReplyProviderStatus(status)) {
      errors++;
      continue;
    }
    try {
      const result = await persistOperatorReplyProviderStatus(admin, {
        providerMessageId,
        status,
        providerErrorCode: typeof raw.provider_error_code === "string" ? raw.provider_error_code : null,
      });
      if (!result.matched) { pending++; continue; }
      const update = await admin.from("debug_webhooks")
        .update({ processed: true, discard_reason: "operator_reply_outbox_reconciled" })
        .eq("id", id)
        .eq("processed", false) as { error: { message: string } | null };
      if (update.error) { errors++; continue; }
      recovered++;
    } catch {
      errors++;
    }
  }
  if (data && data.length > 0) {
    const finalId = String(data[data.length - 1].id ?? "");
    const { error: cursorWriteError } = await admin.from("debug_webhooks")
      .upsert({
        id: cursorId,
        direction: "provider_status_reconciliation_cursor",
        processed: true,
        raw_payload: { last_scanned_id: finalId, version: 1 },
      }, { onConflict: "id" }) as { error: { message: string } | null };
    if (cursorWriteError) throw new Error("WA_STATUS_RECONCILE_CURSOR_WRITE_FAILED");
  }
  return { checked: (data ?? []).length, recovered, pending, errors };
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
    id: await unmatchedStatusAuditUuid(providerMessageId, normalized, event.providerErrorCode),
    direction: "provider_status_unmatched",
    wamid: providerMessageId,
    processed: false,
    discard_reason: "operator_reply_outbox_unmatched",
    error_message: null,
    raw_payload: {
      provider_status: event.status.trim().toLowerCase(),
      target_status: normalized,
      provider_message_id: providerMessageId,
      quarantine: "WA_STATUS_OUTBOX_UNMATCHED",
    },
  }) as { error: { code?: string; message: string } | null };
  // The primary key is derived from provider ID + bounded status, making repeated
  // provider callbacks idempotent even when requests race.
  if (insertResult.error && insertResult.error.code !== "23505") {
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
