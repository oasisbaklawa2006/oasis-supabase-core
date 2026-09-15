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
