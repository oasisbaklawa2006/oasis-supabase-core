import type { ParsedHistoricalMessage } from "./types.ts";

export type MessageAccounting = {
  total_parsed: number;
  system_excluded: number;
  business_received: number;
  certification_windowed: number;
  explicit_non_actionable_ack: number;
  deleted_business: number;
  empty_body_business: number;
  unparsed_sender_business: number;
  unaccounted_business: number;
  balanced: boolean;
};

const ACK_ONLY_RE =
  /^(ok|okay|thanks|thank you|noted|done|received|ok thanks|thanks ok|👍|🙏)\.?\s*$/i;

export function isAcknowledgementOnly(
  message: ParsedHistoricalMessage,
): boolean {
  if (message.is_system || message.is_deleted) return false;
  return ACK_ONLY_RE.test(message.body.trim());
}

export function isActionableForCertification(
  message: ParsedHistoricalMessage,
): boolean {
  if (message.is_system) return false;
  if (message.is_deleted) return false;
  if (!message.body.trim()) return false;
  if (isAcknowledgementOnly(message)) return false;
  return true;
}

export function computeMessageAccounting(
  messages: ParsedHistoricalMessage[],
  windowedFocalIndices: Set<number>,
): MessageAccounting {
  const system = messages.filter((m) => m.is_system);
  const business = messages.filter((m) => !m.is_system);

  let explicitAck = 0;
  let deleted = 0;
  let emptyBody = 0;
  let unparsedSender = 0;
  let windowed = 0;

  for (const message of business) {
    if (message.is_deleted) {
      deleted += 1;
      continue;
    }
    if (!message.body.trim()) {
      emptyBody += 1;
      continue;
    }
    if (message.sender === "[unparsed-sender]") unparsedSender += 1;
    if (windowedFocalIndices.has(message.index)) {
      windowed += 1;
    } else if (isAcknowledgementOnly(message)) {
      explicitAck += 1;
    }
  }

  const activeBusiness = business.length - deleted - emptyBody;
  const accounted = windowed + explicitAck;
  const unaccounted = activeBusiness - accounted;

  return {
    total_parsed: messages.length,
    system_excluded: system.length,
    business_received: business.length,
    certification_windowed: windowed,
    explicit_non_actionable_ack: explicitAck,
    deleted_business: deleted,
    empty_body_business: emptyBody,
    unparsed_sender_business: unparsedSender,
    unaccounted_business: unaccounted,
    balanced: unaccounted === 0,
  };
}
