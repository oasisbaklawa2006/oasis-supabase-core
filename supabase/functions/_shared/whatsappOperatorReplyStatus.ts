export type ProviderStatusEvent = {
  status: string;
  providerMessageId: string | null;
  providerTimestamp?: string | number | null;
};

type RpcError = { message?: string } | null;
type RpcClient = {
  rpc: (
    fn: string,
    args: Record<string, unknown>,
  ) => Promise<{ data: unknown; error: RpcError }>;
};

export type ProviderStatusPersistenceResult = {
  ok: boolean;
  matched: boolean;
  normalizedStatus: "ACCEPTED" | "DELIVERED" | "READ" | null;
  code: string;
};

export function extractProviderStatusEvents(payload: any): ProviderStatusEvent[] {
  const events: ProviderStatusEvent[] = [];
  const entries = Array.isArray(payload?.entry) ? payload.entry : [];

  for (const entry of entries) {
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const statuses = Array.isArray(change?.value?.statuses)
        ? change.value.statuses
        : [];
      for (const status of statuses) {
        if (typeof status?.status !== "string") continue;
        events.push({
          status: status.status,
          providerMessageId: typeof status?.id === "string" ? status.id : null,
          providerTimestamp: status?.timestamp ?? null,
        });
      }
    }
  }

  if (events.length > 0) return events;

  if (Array.isArray(payload?.statuses)) {
    for (const status of payload.statuses) {
      if (typeof status?.status !== "string") continue;
      events.push({
        status: status.status,
        providerMessageId:
          typeof status?.id === "string"
            ? status.id
            : typeof status?.message_id === "string"
              ? status.message_id
              : null,
        providerTimestamp: status?.timestamp ?? null,
      });
    }
  }
  if (events.length > 0) return events;

  const click2apiStatus = typeof payload?.message?.message_status === "string"
    ? payload.message.message_status
    : null;
  if (!click2apiStatus) return [];

  return [{
    status: click2apiStatus,
    providerMessageId:
      typeof payload?.response?.messages?.[0]?.id === "string"
        ? payload.response.messages[0].id
        : typeof payload?.message?.id === "string"
          ? payload.message.id
          : null,
    providerTimestamp: payload?.message?.timestamp ?? payload?.timestamp ?? null,
  }];
}

export function normalizeProviderReplyStatus(
  status: string,
): "ACCEPTED" | "DELIVERED" | "READ" | null {
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

export async function persistOperatorReplyProviderStatus(
  admin: RpcClient,
  event: ProviderStatusEvent,
  provider: string,
): Promise<ProviderStatusPersistenceResult> {
  const normalizedStatus = normalizeProviderReplyStatus(event.status);
  if (!normalizedStatus) {
    return { ok: true, matched: false, normalizedStatus: null, code: "STATUS_IGNORED" };
  }

  const providerMessageId = event.providerMessageId?.trim() ?? "";
  if (!providerMessageId) {
    return {
      ok: true,
      matched: false,
      normalizedStatus,
      code: "PROVIDER_MESSAGE_ID_MISSING",
    };
  }

  const { data, error } = await admin.rpc(
    "record_whatsapp_operator_reply_status",
    {
      p_reply_id: null,
      p_provider: provider,
      p_provider_message_id: providerMessageId,
      p_status: normalizedStatus,
      p_evidence: {
        source: "whatsapp-webhook",
        callback_status: event.status,
        provider_timestamp: event.providerTimestamp ?? null,
      },
    },
  );

  if (error) {
    const message = error.message ?? "";
    if (message.includes("WA5_STATUS_BOUNDARY_OR_REGRESSION")) {
      return {
        ok: true,
        matched: false,
        normalizedStatus,
        code: "NOT_MATCHED_OR_STALE",
      };
    }
    return {
      ok: false,
      matched: false,
      normalizedStatus,
      code: "STATUS_PERSISTENCE_FAILED",
    };
  }

  return {
    ok: true,
    matched: Boolean(data),
    normalizedStatus,
    code: "PERSISTED",
  };
}
