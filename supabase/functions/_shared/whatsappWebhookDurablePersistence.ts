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

/** Stable UUIDv8 key for one inbound provider event's debounced buffer row.
 * The database primary key rejects retries/concurrent duplicate inserts.
 * Never store the provider identifier in the key or log the unhashed source.
 */
export async function stableInboundBufferUuid(providerMessageId: string): Promise<string> {
  if (!providerMessageId.trim()) throw new Error("WA_BUFFER_PROVIDER_ID_REQUIRED");
  const data = new TextEncoder().encode(
    JSON.stringify(["oasis/wa450/buffer/v1", providerMessageId.trim()]),
  );
  const digest = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const value = Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
  return [value.slice(0, 8), value.slice(8, 12), value.slice(12, 16),
    value.slice(16, 20), value.slice(20)].join("-");
}
