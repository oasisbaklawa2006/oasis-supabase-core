export type ErpWhatsAppContactJoin = {
  phone_number: string;
  customer_name: string | null;
};

export type ErpWhatsAppMessageRow = {
  id: string;
  contact_id: string;
  direction: string;
  message_type: string;
  content: string | null;
  provider_message_id: string | null;
  provider: string;
  status: string;
  message_timestamp: string | null;
  created_at: string | null;
  whatsapp_contacts: ErpWhatsAppContactJoin | ErpWhatsAppContactJoin[] | null;
};

export type ErpInboundMapResult =
  | {
      ok: true;
      value: {
        provider_message_id: string;
        sender_phone: string;
        sender_name: string | null;
        message_body: string;
        message_type: string;
        received_at: string;
        raw_payload: Record<string, unknown>;
      };
    }
  | { ok: true; skipped: true; reason: string }
  | { ok: false; error: string };

export type ErpProcessResult =
  | {
      ok: true;
      skipped?: false;
      message_id: string;
      resolver_status: string;
      duplicate?: boolean;
    }
  | { ok: true; skipped: true; reason: string }
  | { ok: false; error: string };

export type ErpProcessDeps = {
  resolve: (
    messageBody: string,
  ) => Promise<{
    resolver_status: "resolved" | "failed";
    resolver_result_json: Record<string, unknown> | null;
  }>;
  rpc: (
    fn: string,
    args: Record<string, unknown>,
  ) => Promise<{
    data: (Record<string, unknown> & { id?: string; resolver_status?: string }) | null;
    error: { message: string; code?: string } | null;
  }>;
};
