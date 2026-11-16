/** Provider acceptance identifiers are not interchangeable with Click2API queue IDs.
 *
 * Prefer a WhatsApp message ID in the provider's Meta-style message array.
 * Preserve legacy queue/transport identifiers only as a last-resort fallback;
 * a queue identifier alone is NOT evidence of delivery or a callback match.
 *
 * A separate provider mapping contract is still required when the API returns
 * only a queue UUID and the delivery callback later contains a Meta wamid.
 */
const asRecord = (value: unknown): Record<string, unknown> | null =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;

const normalizedId = (value: unknown): string | number | null => {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed || null;
  }
  if (typeof value === "number" && Number.isFinite(value)) return value;
  return null;
};

const isExplicitFailure = (value: Record<string, unknown> | null): boolean => {
  if (!value) return false;
  if (value.success === false || value.ok === false) return true;
  const status = typeof value.message_status === "string"
    ? value.message_status.toLowerCase()
    : typeof value.status === "string"
    ? value.status.toLowerCase()
    : "";
  return ["failed", "rejected", "undelivered"].includes(status);
};

export function selectClick2ApiProviderMessageId(
  payload: unknown,
): string | number | null {
  const body = asRecord(payload);
  if (!body) return null;

  const response = asRecord(body.response);
  const nested = asRecord(body.message);
  if (
    isExplicitFailure(body) || isExplicitFailure(response) ||
    isExplicitFailure(nested)
  ) return null;

  // Meta-style send replies: `messages[0].id` or wrapped
  // `response.messages[0].id`, including a message in a multi-part batch.
  // These are preferred over `queue_id` because status callbacks carry wamid.
  const messageCandidates: Array<string | number> = [];
  for (const envelope of [body, response, nested]) {
    const messages = envelope?.messages;
    if (!Array.isArray(messages)) continue;
    for (const rawMessage of messages) {
      const item = asRecord(rawMessage);
      if (!item || isExplicitFailure(item)) continue;
      const id = normalizedId(item.id ?? item.message_id);
      if (id !== null) messageCandidates.push(id);
    }
  }

  const metaId = messageCandidates.find(
    (candidate) => typeof candidate === "string" &&
      candidate.startsWith("wamid."),
  );
  if (metaId != null) return metaId;
  if (messageCandidates.length) return messageCandidates[0];

  // Compatibility fallback. A Click2API `queue_id` is a transport
  // acknowledgement only; it must never be interpreted as `delivered`.
  for (
    const candidate of [
      body.message_id,
      body.id,
      response?.message_id,
      response?.id,
      nested?.message_id,
      nested?.id,
      body.queue_id,
      response?.queue_id,
      nested?.queue_id,
    ]
  ) {
    const id = normalizedId(candidate);
    if (id !== null) return id;
  }
  return null;
}
