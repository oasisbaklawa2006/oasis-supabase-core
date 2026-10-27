/** True when any Meta entry/change carries a non-empty inbound messages array. */
export function payloadContainsInboundMessages(payload: unknown): boolean {
  if (!payload || typeof payload !== "object") return false;
  const root = payload as Record<string, unknown>;
  if (!Array.isArray(root.entry)) return false;
  return root.entry.some((rawEntry) => {
    const entry = rawEntry as Record<string, unknown>;
    if (!Array.isArray(entry.changes)) return false;
    return entry.changes.some((rawChange) => {
      const change = rawChange as Record<string, unknown>;
      const value = change.value as Record<string, unknown> | undefined;
      const messages = value?.messages;
      return Array.isArray(messages) && messages.length > 0;
    });
  });
}

/**
 * Expand a Meta webhook payload into one synthetic payload per inbound message so
 * each message is processed independently (dedupe, durable capture, fan-out).
 */
export function enumerateInboundPayloads(payload: unknown): unknown[] {
  if (!payload || typeof payload !== "object") return [payload];
  const root = payload as Record<string, unknown>;
  if (!Array.isArray(root.entry)) return [payload];

  const singles: unknown[] = [];
  for (let entryIndex = 0; entryIndex < root.entry.length; entryIndex++) {
    const entry = root.entry[entryIndex] as Record<string, unknown>;
    const changes = entry.changes;
    if (!Array.isArray(changes)) continue;
    for (let changeIndex = 0; changeIndex < changes.length; changeIndex++) {
      const change = changes[changeIndex] as Record<string, unknown>;
      const value = change.value as Record<string, unknown> | undefined;
      const messages = value?.messages;
      if (!Array.isArray(messages) || messages.length === 0) continue;
      for (let messageIndex = 0; messageIndex < messages.length; messageIndex++) {
        const cloned = structuredClone(payload) as Record<string, unknown>;
        const clonedEntry = (cloned.entry as unknown[])[entryIndex] as Record<string, unknown>;
        const clonedChanges = clonedEntry.changes as unknown[];
        for (let ci = 0; ci < clonedChanges.length; ci++) {
          const clonedChange = clonedChanges[ci] as Record<string, unknown>;
          const clonedValue = clonedChange.value as Record<string, unknown> | undefined;
          if (!clonedValue || !Array.isArray(clonedValue.messages)) continue;
          if (ci === changeIndex) {
            clonedValue.messages = [clonedValue.messages[messageIndex]];
          } else {
            delete clonedValue.messages;
          }
        }
        singles.push(cloned);
      }
    }
  }
  return singles.length > 0 ? singles : [payload];
}
