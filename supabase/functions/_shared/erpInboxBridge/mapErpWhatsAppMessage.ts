import type { ErpInboundMapResult, ErpWhatsAppMessageRow } from "./types.ts";

const SUPPORTED_TEXT_TYPES = new Set(["text", "interactive", "button"]);

export function normalizeErpPhone(phone: string | null | undefined): string {
  const trimmed = (phone ?? "").trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("+")) return trimmed;
  if (/^\d+$/.test(trimmed)) return `+${trimmed}`;
  return trimmed;
}

export function erpTimestampToIso(timestamp: string | null | undefined): string {
  if (!timestamp) return new Date().toISOString();
  const trimmed = timestamp.trim();
  if (trimmed.includes("T")) {
    return trimmed.endsWith("Z") || /[+-]\d{2}:\d{2}$/.test(trimmed) ? trimmed : `${trimmed}Z`;
  }
  return `${trimmed.replace(" ", "T")}Z`;
}

function contactFromRow(row: ErpWhatsAppMessageRow) {
  const joined = row.whatsapp_contacts;
  if (Array.isArray(joined)) return joined[0] ?? null;
  return joined;
}

export function mapErpWhatsAppMessage(row: ErpWhatsAppMessageRow): ErpInboundMapResult {
  if ((row.direction ?? "").toLowerCase() !== "inbound") {
    return { ok: true, skipped: true, reason: `outbound ERP row (${row.direction})` };
  }

  const messageType = (row.message_type ?? "text").trim().toLowerCase();
  if (!SUPPORTED_TEXT_TYPES.has(messageType)) {
    return { ok: true, skipped: true, reason: `unsupported message type: ${messageType}` };
  }

  const contact = contactFromRow(row);
  const sender_phone = normalizeErpPhone(contact?.phone_number);
  if (!sender_phone) {
    return { ok: false, error: "sender_phone is required" };
  }

  const message_body = (row.content ?? "").trim();
  if (!message_body) {
    return { ok: true, skipped: true, reason: "empty message_body" };
  }

  const provider_message_id = (row.provider_message_id ?? "").trim() || `erp:${row.id}`;

  return {
    ok: true,
    value: {
      provider_message_id,
      sender_phone,
      sender_name: contact?.customer_name?.trim() || null,
      message_body,
      message_type: messageType,
      received_at: erpTimestampToIso(row.message_timestamp ?? row.created_at),
      raw_payload: {
        bridge_source: "erp_whatsapp_messages",
        erp_row_id: row.id,
        erp_contact_id: row.contact_id,
        erp_provider: row.provider,
        erp_status: row.status,
        erp_message_timestamp: row.message_timestamp,
      },
    },
  };
}
