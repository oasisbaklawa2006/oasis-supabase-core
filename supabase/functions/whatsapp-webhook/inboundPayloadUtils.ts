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

function copyTopLevelFields(root: Record<string, unknown>): Record<string, unknown> {
  const copy: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(root)) {
    if (key !== "entry") copy[key] = value;
  }
  return copy;
}

/**
 * Expand a Meta webhook payload into one synthetic payload per inbound message.
 * Each synthetic payload contains exactly one entry, one change, and one message so
 * `extractPayloadFields` (entry[0]/changes[0]/messages[0]) cannot alias another slice.
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
        const message = messages[messageIndex] as Record<string, unknown>;
        const isolatedValue: Record<string, unknown> = {};
        if (value) {
          for (const [key, fieldValue] of Object.entries(value)) {
            if (key === "messages" || key === "statuses") continue;
            isolatedValue[key] = fieldValue;
          }
        }
        isolatedValue.messages = [message];
        const sender = typeof message.from === "string" ? message.from : null;
        if (Array.isArray(value?.contacts)) {
          const contacts = (value.contacts as Record<string, unknown>[]).filter((contact) =>
            sender && contact.wa_id === sender
          );
          if (contacts.length > 0) isolatedValue.contacts = contacts;
        }

        singles.push({
          ...copyTopLevelFields(root),
          entry: [{
            ...structuredClone(entry),
            changes: [{
              ...structuredClone(change),
              value: isolatedValue,
            }],
          }],
        });
      }
    }
  }
  return singles.length > 0 ? singles : [payload];
}
