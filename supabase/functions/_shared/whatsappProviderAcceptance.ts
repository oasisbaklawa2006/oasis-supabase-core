export function selectClick2ApiProviderMessageId(
  payload: unknown,
): string | number | null {
  if (!payload || typeof payload !== "object") return null;
  const body = payload as Record<string, unknown>;
  const nested = body.message && typeof body.message === "object"
    ? body.message as Record<string, unknown>
    : {};

  for (
    const candidate of [
      body.message_id,
      body.id,
      body.queue_id,
      nested.message_id,
      nested.id,
      nested.queue_id,
    ]
  ) {
    if (typeof candidate === "string" && candidate.trim()) return candidate;
    if (typeof candidate === "number" && Number.isFinite(candidate)) {
      return candidate;
    }
  }
  return null;
}
