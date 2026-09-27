/** Governed persistence for provider-authenticated WhatsApp status callbacks. Release-wave certified path. */

export type ProviderStatusEvent = {
  status: string;
  providerMessageId: string | null;
};

type QueryResult<T> = { data: T | null; error: { message: string } | null };

type AdminClient = {
  from: (table: string) => any;
};

const STATUS_RANK: Record<string, number> = {
  QUEUED: 0,
  SENDING: 1,
  ACCEPTANCE_UNKNOWN: 1,
  ACCEPTED: 2,
  DELIVERED: 3,
  READ: 4,
};

export function normalizeOperatorReplyProviderStatus(status: string): "ACCEPTED" | "DELIVERED" | "READ" | null {
  switch (status.trim().toLowerCase()) {
    case "sent":
    case "accepted":
      return "ACCEPTED";
    case "delivered":
      return "DELIVERED";
    case "read":
      return "READ";
    default:
      return null;
  }
}

export function shouldAdvanceOperatorReplyStatus(current: string, target: string): boolean {
  const currentRank = STATUS_RANK[current.toUpperCase()] ?? -1;
  const targetRank = STATUS_RANK[target.toUpperCase()] ?? -1;
  return targetRank >= 0 && targetRank > currentRank;
}

export async function persistOperatorReplyProviderStatus(
  admin: AdminClient,
  event: ProviderStatusEvent,
): Promise<{ matched: boolean; updated: boolean; status: string | null }> {
  const providerMessageId = event.providerMessageId?.trim() ?? "";
  const targetStatus = normalizeOperatorReplyProviderStatus(event.status);
  if (!providerMessageId || !targetStatus) {
    return { matched: false, updated: false, status: null };
  }

  const lookup = await admin
    .from("whatsapp_operator_reply_outbox")
    .select("id,status,accepted_at,delivered_at,read_at")
    .eq("provider_message_id", providerMessageId)
    .maybeSingle() as QueryResult<Record<string, unknown>>;

  if (lookup.error) throw new Error(`WA_STATUS_LOOKUP_FAILED:${lookup.error.message.slice(0, 160)}`);
  if (!lookup.data?.id) return { matched: false, updated: false, status: null };

  const currentStatus = String(lookup.data.status ?? "");
  if (!shouldAdvanceOperatorReplyStatus(currentStatus, targetStatus)) {
    return { matched: true, updated: false, status: currentStatus };
  }

  const evidenceWrite = await admin
    .from("whatsapp_operator_reply_events")
    .insert({
      reply_id: lookup.data.id,
      event_type: "PROVIDER_STATUS_CALLBACK",
      actor_id: null,
      evidence: {
        provider_status: event.status.trim().toLowerCase(),
        target_status: targetStatus,
        provider_message_id_present: true,
      },
    }) as QueryResult<unknown>;
  if (evidenceWrite.error) {
    throw new Error(`WA_STATUS_EVENT_WRITE_FAILED:${evidenceWrite.error.message.slice(0, 160)}`);
  }

  const now = new Date().toISOString();
  const patch: Record<string, unknown> = {
    status: targetStatus,
    updated_at: now,
  };
  if (!lookup.data.accepted_at) patch.accepted_at = now;
  if ((targetStatus === "DELIVERED" || targetStatus === "READ") && !lookup.data.delivered_at) {
    patch.delivered_at = now;
  }
  if (targetStatus === "READ" && !lookup.data.read_at) patch.read_at = now;

  const update = await admin
    .from("whatsapp_operator_reply_outbox")
    .update(patch)
    .eq("id", lookup.data.id)
    .eq("status", currentStatus)
    .select("status")
    .maybeSingle() as QueryResult<Record<string, unknown>>;

  if (update.error) throw new Error(`WA_STATUS_UPDATE_FAILED:${update.error.message.slice(0, 160)}`);
  if (!update.data) {
    const reread = await admin
      .from("whatsapp_operator_reply_outbox")
      .select("status")
      .eq("id", lookup.data.id)
      .maybeSingle() as QueryResult<Record<string, unknown>>;
    if (reread.error) throw new Error(`WA_STATUS_REREAD_FAILED:${reread.error.message.slice(0, 160)}`);
    return { matched: true, updated: false, status: String(reread.data?.status ?? currentStatus) };
  }

  return { matched: true, updated: true, status: String(update.data.status ?? targetStatus) };
}
