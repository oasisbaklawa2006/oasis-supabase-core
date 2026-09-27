import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import type { WebhookStatusEvent } from "./whatsappWebhookBoundary.ts";

type AdminClient = SupabaseClient;

export type ProviderStatusPersistenceResult = {
  ok: boolean;
  matched: boolean;
  normalizedStatus: "ACCEPTED" | "DELIVERED" | "READ" | null;
  code: string;
};

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
  admin: AdminClient,
  event: WebhookStatusEvent,
  provider: string,
): Promise<ProviderStatusPersistenceResult> {
  const normalizedStatus = normalizeProviderReplyStatus(event.status);
  if (!normalizedStatus) {
    return {
      ok: true,
      matched: false,
      normalizedStatus: null,
      code: "STATUS_IGNORED",
    };
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
