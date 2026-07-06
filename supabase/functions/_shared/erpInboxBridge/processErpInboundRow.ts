import { mapErpWhatsAppMessage } from "./mapErpWhatsAppMessage.ts";
import type { ErpProcessDeps, ErpProcessResult, ErpWhatsAppMessageRow } from "./types.ts";

export async function processErpInboundRow(
  row: ErpWhatsAppMessageRow,
  deps: ErpProcessDeps,
): Promise<ErpProcessResult> {
  const mapped = mapErpWhatsAppMessage(row);
  if (!mapped.ok) {
    return { ok: false, error: mapped.error };
  }
  if ("skipped" in mapped && mapped.skipped) {
    return { ok: true, skipped: true, reason: mapped.reason };
  }

  try {
    let resolved: Awaited<ReturnType<ErpProcessDeps["resolve"]>>;
    try {
      resolved = await deps.resolve(mapped.value.message_body);
    } catch {
      resolved = { resolver_status: "failed", resolver_result_json: null };
    }

    const { data, error } = await deps.rpc("ingest_whatsapp_inbound_message", {
      _provider_message_id: mapped.value.provider_message_id,
      _sender_phone: mapped.value.sender_phone,
      _sender_name: mapped.value.sender_name,
      _message_body: mapped.value.message_body,
      _message_type: mapped.value.message_type,
      _received_at: mapped.value.received_at,
      _raw_payload: mapped.value.raw_payload,
      _resolver_status: resolved.resolver_status,
      _resolver_result_json: resolved.resolver_result_json,
    });

    if (error) {
      return { ok: false, error: error.message };
    }
    if (!data?.id) {
      return { ok: false, error: "ingest returned no row" };
    }

    const duplicate = Boolean((data as Record<string, unknown>).__ingest_duplicate);
    return {
      ok: true,
      message_id: String(data.id),
      resolver_status: String(data.resolver_status ?? resolved.resolver_status),
      duplicate,
    };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "erp bridge ingest failed" };
  }
}
