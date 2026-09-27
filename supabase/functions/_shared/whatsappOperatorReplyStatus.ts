/** Governed persistence for provider-authenticated WhatsApp status callbacks. Release-wave certified path. */

export type ProviderStatusEvent = {
  status: string;
  providerMessageId: string | null;
};

type QueryResult<T> = { data: T | null; error: { message: string } | null };

type AdminClient = {
  rpc: (fn: string, args: Record<string, unknown>) => any;
};

const STATUS_RANK: Record<string, number> = {
  QUEUED: 0,
  SENDING: 1,
  ACCEPTANCE_UNKNOWN: 1,
  ACCEPTED: 2,
  DELIVERED: 3,
  READ: 4,
};

/** Normalize provider callbacks to the bounded delivery lifecycle persisted by Core. */
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

/** Return true only for a strictly monotonic provider-status transition. */
export function shouldAdvanceOperatorReplyStatus(current: string, target: string): boolean {
  const currentRank = STATUS_RANK[current.toUpperCase()] ?? -1;
  const targetRank = STATUS_RANK[target.toUpperCase()] ?? -1;
  return targetRank >= 0 && targetRank > currentRank;
}

/** Persist one provider callback through the service-role atomic Postgres RPC. */
export async function persistOperatorReplyProviderStatus(
  admin: AdminClient,
  event: ProviderStatusEvent,
): Promise<{ matched: boolean; updated: boolean; status: string | null }> {
  const providerMessageId = event.providerMessageId?.trim() ?? "";
  const targetStatus = normalizeOperatorReplyProviderStatus(event.status);
  if (!providerMessageId || !targetStatus) {
    return { matched: false, updated: false, status: null };
  }

  const rpcResult = await admin.rpc("persist_whatsapp_operator_reply_provider_status", {
    p_provider_message_id: providerMessageId,
    p_status: targetStatus,
    p_evidence: {
      provider_status: event.status.trim().toLowerCase(),
      target_status: targetStatus,
      provider_message_id_present: true,
    },
  }) as QueryResult<Record<string, unknown>>;

  if (rpcResult.error) {
    throw new Error(`WA_STATUS_RPC_FAILED:${rpcResult.error.message.slice(0, 160)}`);
  }

  const payload = rpcResult.data ?? {};
  return {
    matched: payload.matched === true,
    updated: payload.updated === true,
    status: typeof payload.status === "string" ? payload.status : null,
  };
}
