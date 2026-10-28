/** PostgREST/Supabase error shape for whatsapp_messages insert outcomes. */
export type WhatsappMessagesInsertError = {
  code?: string;
  message?: string;
};

export type DurablePersistenceDecision =
  | { ok: true; duplicate: boolean }
  | { ok: false };

/**
 * Decide whether inbound webhook processing may acknowledge provider success.
 * Operational durable ownership requires a whatsapp_messages row (or an
 * authoritative duplicate on provider_message_id).
 */
export function evaluateWhatsappMessagesPersistence(
  requiresDurableOwnership: boolean,
  contactId: string | null | undefined,
  insertError: WhatsappMessagesInsertError | null | undefined,
): DurablePersistenceDecision {
  if (!requiresDurableOwnership) {
    return { ok: true, duplicate: false };
  }
  if (!contactId) {
    return { ok: false };
  }
  if (!insertError) {
    return { ok: true, duplicate: false };
  }
  if (insertError.code === "23505") {
    return { ok: true, duplicate: true };
  }
  return { ok: false };
}

export function durablePersistenceFailed(
  requiresDurableOwnership: boolean,
  contactId: string | null | undefined,
  insertError: WhatsappMessagesInsertError | null | undefined,
  threw: boolean,
): boolean {
  if (threw) return requiresDurableOwnership;
  const decision = evaluateWhatsappMessagesPersistence(
    requiresDurableOwnership,
    contactId,
    insertError,
  );
  return !decision.ok;
}

/**
 * Debug-table direction of the receipt row written once an inbound message has completed
 * every required processing step. Durable ownership (a `whatsapp_messages` row) is NOT
 * completion: the buffer, dispute and media steps happen around it, so a provider retry
 * may only be acknowledged as a plain duplicate when this receipt exists. If the receipt
 * is missing or unreadable the retry safely re-runs the idempotent pipeline instead.
 */
export const INBOUND_COMPLETION_DIRECTION = "inbound_completion";

/** Side-effect families that need a stable per-message identity. */
export type InboundEffectKind = "buffer" | "dispute" | "interaction" | "media";

/**
 * Stable UUIDv8 for one effect of one inbound provider event. Retries and concurrent
 * deliveries derive the same key, so the database primary key rejects the duplicate.
 * Never store the provider identifier in the key or log the unhashed source.
 * The "buffer" kind is byte-compatible with the original buffer-only helper.
 */
export async function stableInboundEffectUuid(
  kind: InboundEffectKind,
  providerMessageId: string,
): Promise<string> {
  const id = String(providerMessageId ?? "").trim();
  if (!id) {
    throw new Error(kind === "buffer" ? "WA_BUFFER_PROVIDER_ID_REQUIRED" : "WA_EFFECT_PROVIDER_ID_REQUIRED");
  }
  const data = new TextEncoder().encode(JSON.stringify([`oasis/wa450/${kind}/v1`, id]));
  const digest = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const value = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  return [value.slice(0, 8), value.slice(8, 12), value.slice(12, 16),
    value.slice(16, 20), value.slice(20)].join("-");
}

/** Stable UUIDv8 key for one inbound provider event's debounced buffer row. */
export function stableInboundBufferUuid(providerMessageId: string): Promise<string> {
  return stableInboundEffectUuid("buffer", providerMessageId);
}

/**
 * Deterministic storage object name for one inbound attachment, so a replay addresses the
 * same object instead of uploading a new copy. Provider media is immutable per message id.
 */
export async function inboundMediaObjectName(
  senderKey: string,
  providerMessageId: string,
  extension: string,
): Promise<string> {
  return `${senderKey}/${await stableInboundEffectUuid("media", providerMessageId)}.${extension}`;
}

/** True when a storage upload failed only because the (deterministic) object already exists. */
export function isStorageObjectExistsError(
  error: { statusCode?: string | number; message?: string } | null | undefined,
): boolean {
  if (!error) return false;
  if (String(error.statusCode ?? "") === "409") return true;
  return /already exists|duplicate/i.test(error.message ?? "");
}
