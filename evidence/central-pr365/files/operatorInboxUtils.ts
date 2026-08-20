/**
 * Pure helpers for the operator WhatsApp inbox (read-only / local-only previews).
 * No network calls; no persistence.
 */

import type { Message } from "./operatorInboxTypes";
import type { GovernedEvidenceLink, GovernedEvidenceProcessingState } from "./operatorInboxPacketsLoader";

export type DayGroupedMessages = { dayKey: string; dayLabel: string; messages: Message[] };

/**
 * Deterministic chronological order for thread semantics:
 * created_at ascending, then packet_sequence ascending, then id ascending.
 */
export function compareMessagesChronological(a: Message, b: Message): number {
  const ta = a.created_at ? new Date(a.created_at).getTime() : 0;
  const tb = b.created_at ? new Date(b.created_at).getTime() : 0;
  if (ta !== tb) return ta - tb;
  const sa = a.packet_sequence ?? 0;
  const sb = b.packet_sequence ?? 0;
  if (sa !== sb) return sa - sb;
  return String(a.id).localeCompare(String(b.id));
}

export function sortMessagesChronological(messages: Message[]): Message[] {
  return [...messages].sort(compareMessagesChronological);
}

/** Group messages by local calendar day for thread UI. */
export function groupMessagesByDay(messages: Message[], locale = "en-IN"): DayGroupedMessages[] {
  const sorted = sortMessagesChronological(messages);

  const byKey = new Map<string, { label: string; items: Message[] }>();
  for (const msg of sorted) {
    const d = msg.created_at ? new Date(msg.created_at) : null;
    const key = d
      ? `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`
      : "unknown";
    const dayLabel = d
      ? d.toLocaleDateString(locale, { weekday: "short", month: "short", day: "numeric" })
      : "Unknown date";
    if (!byKey.has(key)) {
      byKey.set(key, { label: dayLabel, items: [] });
    }
    byKey.get(key)!.items.push(msg);
  }

  return Array.from(byKey.entries()).map(([dayKey, v]) => ({
    dayKey,
    dayLabel: v.label,
    messages: v.items,
  }));
}

/** Local-only draft / order hints from visible message text (inbound preferred). */
export function extractDraftOrderHints(messages: Message[], maxHints = 10): string[] {
  const inbound = messages.filter((m) => m.direction === "inbound");
  const text = inbound
    .map((m) => m.content ?? "")
    .join("\n")
    .slice(0, 12000);

  const hints = new Set<string>();

  const soMatches = text.matchAll(/\bSO[-\s]?\d{4,}\b/gi);
  for (const m of soMatches) {
    hints.add(`Order ref: ${m[0].toUpperCase().replace(/\s+/g, "-")}`);
    if (hints.size >= maxHints) return [...hints];
  }

  const gstMatches = text.matchAll(/\b\d{2}[A-Z]{5}\d{4}[A-Z][A-Z0-9]Z[A-Z0-9]\b/gi);
  for (const m of gstMatches) {
    hints.add(`GSTIN-like: ${m[0]}`);
    if (hints.size >= maxHints) return [...hints];
  }

  const inrMatches = text.matchAll(/(?:₹|Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?/gi);
  for (const m of inrMatches) {
    hints.add(`Amount: ${m[0].trim()}`);
    if (hints.size >= maxHints) return [...hints];
  }

  const qtyMatches = text.matchAll(/\b\d+\s*(?:kg|g|pcs|pieces|boxes|dozen)\b/gi);
  for (const m of qtyMatches) {
    hints.add(`Qty / unit: ${m[0]}`);
    if (hints.size >= maxHints) return [...hints];
  }

  if (hints.size === 0) {
    hints.add("No draft-like tokens detected in inbound text (local parse only).");
  }

  return [...hints].slice(0, maxHints);
}

/** Local-only “AI-style” preview — keyword heuristics only, not model output. */
export function localOnlyAiSuggestionPreview(messages: Message[]): {
  headline: string;
  bullets: string[];
} {
  const inbound = messages.filter((m) => m.direction === "inbound");
  const text = inbound
    .map((m) => m.content ?? "")
    .join(" ")
    .toLowerCase();

  const bullets: string[] = [];
  let headline = "General thread";

  if (/dispatch|dispatched|tracking|awb|courier|delivery/.test(text)) {
    headline = "Likely logistics / dispatch";
    bullets.push("Keywords suggest shipment or tracking questions.");
  } else if (/payment|pay|upi|invoice|gst|advance|due/.test(text)) {
    headline = "Likely payment / billing";
    bullets.push("Keywords suggest payment, invoice, or tax context.");
  } else if (/price|rate|quote|quotation|moq|discount/.test(text)) {
    headline = "Likely pricing / commercial";
    bullets.push("Keywords suggest pricing or negotiation.");
  } else if (/complaint|damage|wrong|issue|return/.test(text)) {
    headline = "Likely support / quality";
    bullets.push("Keywords suggest an issue or complaint.");
  } else {
    bullets.push("No strong keyword bucket matched — use Classify Intent for a real model suggestion.");
  }

  bullets.push("Preview is computed in-browser only; nothing is saved.");

  return { headline, bullets };
}

export function uniqueMessageStatuses(messages: Message[]): string[] {
  const s = new Set<string>();
  for (const m of messages) {
    if (m.status?.trim()) s.add(m.status.trim());
  }
  return [...s].sort();
}

export function uniqueProviders(messages: Message[]): string[] {
  const s = new Set<string>();
  for (const m of messages) {
    if (m.provider?.trim()) s.add(m.provider.trim());
  }
  return [...s].sort();
}

const ATTACHMENT_TYPE = /image|document|video|audio|sticker|media|application|pdf|vcard/i;

/** Heuristic only — does not fetch media binaries */
export function messageHasAttachmentHint(m: Message): boolean {
  if (ATTACHMENT_TYPE.test(m.message_type || "")) return true;
  const c = (m.content ?? "").trim();
  if (!c) return false;
  return /\bhttps?:\/\//i.test(c);
}

/**
 * Packet-level (never global) media presence/status for a single message, derived
 * from the governed `whatsapp_commercial_evidence` row already fetched for this
 * packet's own provider_message_ids — never a raw storage URL, never a global count.
 * "none" covers both text-only messages (media_count === 0) and messages the
 * operator inbox has no governed evidence context for yet.
 */
export type MessageMediaStatus = "available" | "processing" | "failed" | "unreadable" | "none";

const MEDIA_PROCESSING_STATE_TO_STATUS: Record<GovernedEvidenceProcessingState, MessageMediaStatus> = {
  SUCCEEDED: "available",
  PENDING: "processing",
  PROCESSING: "processing",
  FAILED: "failed",
  TIMED_OUT: "failed",
  CORRUPT: "unreadable",
  UNREADABLE: "unreadable",
  UNSUPPORTED: "unreadable",
};

export function deriveMessageMediaStatus(
  evidence: GovernedEvidenceLink | null | undefined,
): MessageMediaStatus {
  if (!evidence || evidence.media_count <= 0) return "none";
  return MEDIA_PROCESSING_STATE_TO_STATUS[evidence.processing_state] ?? "processing";
}

export function findEvidenceForMessage(
  evidenceLinks: GovernedEvidenceLink[],
  providerMessageId: string | null | undefined,
): GovernedEvidenceLink | null {
  if (!providerMessageId) return null;
  return evidenceLinks.find((e) => e.provider_message_id === providerMessageId) ?? null;
}

/** Local intent bucket for sidebar / row coloring (keyword + stitched text). */
export type LocalIntentTone = "slate" | "blue" | "amber" | "rose" | "violet" | "emerald";

export function inferLocalIntentFromText(
  stitchedOrInboundText: string,
): { label: string; tone: LocalIntentTone } {
  const t = stitchedOrInboundText.toLowerCase();
  if (/dispatch|dispatched|tracking|awb|courier|delivery|transit/.test(t)) {
    return { label: "Logistics", tone: "blue" };
  }
  if (/payment|pay|upi|invoice|gst|advance|due|refund/.test(t)) {
    return { label: "Billing", tone: "violet" };
  }
  if (/price|rate|quote|quotation|moq|discount|offer/.test(t)) {
    return { label: "Commercial", tone: "emerald" };
  }
  if (/complaint|damage|wrong|issue|return|defect/.test(t)) {
    return { label: "Support", tone: "rose" };
  }
  if (/urgent|asap|immediately|today|now\b/.test(t)) {
    return { label: "Urgent tone", tone: "amber" };
  }
  return { label: "General", tone: "slate" };
}

const INTENT_TONE_ACCENT: Record<LocalIntentTone, string> = {
  slate: "border-l-slate-300",
  blue: "border-l-blue-500",
  amber: "border-l-amber-500",
  rose: "border-l-rose-500",
  violet: "border-l-violet-500",
  emerald: "border-l-emerald-500",
};

/** Left border classes for packet list rows (Tailwind). */
export function operatorInboxIntentRowBorderClass(tone: LocalIntentTone): string {
  return `border-l-4 ${INTENT_TONE_ACCENT[tone]}`;
}

export function packetStitchedPlainText(stitchedContent: unknown): string {
  if (stitchedContent == null) return "";
  if (typeof stitchedContent === "string") return stitchedContent;
  if (typeof stitchedContent === "object" && !Array.isArray(stitchedContent)) {
    const o = stitchedContent as Record<string, unknown>;
    const text = o.text;
    const summary = o.summary;
    const parts: string[] = [];
    if (typeof text === "string") parts.push(text);
    if (typeof summary === "string") parts.push(summary);
    return parts.join("\n");
  }
  return "";
}

/** Age bucket from last activity (read-only UX). */
export type PacketAgeBucket = "fresh" | "active" | "aging" | "stale";

/**
 * SLA-style labels for idle time since last packet activity (read-only).
 * Buckets: under 15m fresh · 15m–2h watch · 2h–24h aging · 24h+ stale.
 */
export function packetSlaUiMeta(age: PacketAgeBucket): { title: string; range: string } {
  switch (age) {
    case "fresh":
      return { title: "Fresh", range: "<15m" };
    case "active":
      return { title: "Watch", range: "15m–2h" };
    case "aging":
      return { title: "Aging", range: "2h–24h" };
    case "stale":
      return { title: "Stale", range: "24h+" };
    default:
      return { title: "Watch", range: "15m–2h" };
  }
}

export function packetAgeBucket(lastMessageAtIso: string, now = Date.now()): PacketAgeBucket {
  const t = new Date(lastMessageAtIso).getTime();
  if (Number.isNaN(t)) return "active";
  const mins = (now - t) / 60000;
  if (mins < 15) return "fresh";
  if (mins < 120) return "active";
  if (mins < 1440) return "aging";
  return "stale";
}

export function isLastMessageInboundUnanswered(messages: Message[]): boolean {
  const sorted = sortMessagesChronological(messages);
  const last = sorted[sorted.length - 1];
  return Boolean(last && last.direction === "inbound");
}

/** Median seconds from each inbound to the next outbound in the thread (read-only estimate). */
export function medianResponseLagSeconds(messages: Message[]): number | null {
  const sorted = sortMessagesChronological(messages);
  const lags: number[] = [];
  for (let i = 0; i < sorted.length - 1; i++) {
    const cur = sorted[i];
    if (cur.direction !== "inbound" || !cur.created_at) continue;
    const nextOut = sorted.slice(i + 1).find((m) => m.direction === "outbound" && m.created_at);
    if (!nextOut?.created_at) continue;
    const sec = (new Date(nextOut.created_at).getTime() - new Date(cur.created_at).getTime()) / 1000;
    if (sec >= 0 && sec < 86400 * 7) lags.push(sec);
  }
  if (lags.length === 0) return null;
  lags.sort((a, b) => a - b);
  const mid = Math.floor(lags.length / 2);
  return lags.length % 2 ? lags[mid]! : (lags[mid - 1]! + lags[mid]!) / 2;
}

export function stitchedContentLooksClassified(stitchedContent: unknown): boolean {
  if (!stitchedContent || typeof stitchedContent !== "object" || Array.isArray(stitchedContent)) {
    return false;
  }
  const o = stitchedContent as Record<string, unknown>;
  return Boolean(
    o.intent_type ||
      o.intent ||
      o.classification ||
      o.classified_intent ||
      (o.metadata && typeof o.metadata === "object"),
  );
}

export interface CustomerActivitySummary {
  firstAt: string | null;
  lastAt: string | null;
  inbound: number;
  outbound: number;
  spanMinutes: number | null;
}

export function summarizeCustomerActivity(messages: Message[]): CustomerActivitySummary {
  const inbound = messages.filter((m) => m.direction === "inbound").length;
  const outbound = messages.filter((m) => m.direction === "outbound").length;
  const times = messages
    .map((m) => (m.created_at ? new Date(m.created_at).getTime() : NaN))
    .filter((n) => !Number.isNaN(n));
  const firstAt = times.length ? new Date(Math.min(...times)).toISOString() : null;
  const lastAt = times.length ? new Date(Math.max(...times)).toISOString() : null;
  let spanMinutes: number | null = null;
  if (firstAt && lastAt) {
    spanMinutes = (new Date(lastAt).getTime() - new Date(firstAt).getTime()) / 60000;
  }
  return { firstAt, lastAt, inbound, outbound, spanMinutes };
}

export type PacketHealth = "healthy" | "needs_reply" | "stale_open" | "operator_issue";

const HARD_FAILED_OPERATOR_REPLY_STATUSES = new Set(["failed", "error"]);
const PENDING_OPERATOR_REPLY_STATUSES = new Set([
  "acceptance_unknown",
  "reconciliation_pending",
  "pending",
  "queued",
  "submitted",
  "sent",
  "delivered",
]);

/** Outbound operator_reply rows that are genuinely failed — not pending reconciliation. */
export function isHardFailedOperatorReply(message: Message): boolean {
  if (message.direction !== "outbound" || message.provider !== "operator_reply") return false;
  const status = typeof message.status === "string" ? message.status.trim().toLowerCase() : "";
  if (!status) return false;
  if (PENDING_OPERATOR_REPLY_STATUSES.has(status)) return false;
  return HARD_FAILED_OPERATOR_REPLY_STATUSES.has(status);
}

export function inferPacketHealth(
  lastMessageAtIso: string,
  messages: Message[],
): PacketHealth {
  const unanswered = isLastMessageInboundUnanswered(messages);
  const failedOut = messages.some((m) => isHardFailedOperatorReply(m));
  if (failedOut) return "operator_issue";
  const age = packetAgeBucket(lastMessageAtIso);
  if (unanswered && age === "stale") return "stale_open";
  if (unanswered) return "needs_reply";
  return "healthy";
}

/** Operator-reply send failures only — matches `inferPacketHealth` → `operator_issue` criteria (read-only panel). */
export function selectFailedMessagesForReadOnlyPanel(messages: Message[]): Message[] {
  return sortMessagesChronological(messages).filter((m) => isHardFailedOperatorReply(m));
}

export function aggregateProviderCounts(
  rows: { provider?: string | null }[],
): { provider: string; count: number }[] {
  const map = new Map<string, number>();
  for (const r of rows) {
    const p = (r.provider ?? "").trim() || "unknown";
    map.set(p, (map.get(p) ?? 0) + 1);
  }
  return [...map.entries()]
    .map(([provider, count]) => ({ provider, count }))
    .sort((a, b) => b.count - a.count);
}

/** Insert subtle timeline dividers when gap between consecutive messages exceeds threshold (minutes). */
export function messagePairsWithGapMarkers(
  messages: Message[],
  gapMinutes = 240,
): { before: Message | null; message: Message; showGap: boolean }[] {
  const sorted = sortMessagesChronological(messages);
  return sorted.map((message, idx) => {
    const prev = idx > 0 ? sorted[idx - 1]! : null;
    let showGap = false;
    if (prev?.created_at && message.created_at) {
      const gapMs = new Date(message.created_at).getTime() - new Date(prev.created_at).getTime();
      showGap = gapMs > gapMinutes * 60_000;
    }
    return { before: prev, message, showGap };
  });
}

/** Calendar-day groups where gap markers were computed on the full thread (cross-midnight gaps included). */
export type DayGroupedGapMarkedMessages = {
  dayKey: string;
  dayLabel: string;
  items: { message: Message; showGap: boolean }[];
};

/**
 * Like grouping by day for the thread UI, but gap markers use the full chronological message list
 * so idle periods spanning calendar days still show a "Long gap" divider.
 */
export function groupMessagesByDayWithGapMarkers(
  messages: Message[],
  gapMinutes = 240,
  locale = "en-IN",
): DayGroupedGapMarkedMessages[] {
  const pairs = messagePairsWithGapMarkers(messages, gapMinutes);
  const byKey = new Map<string, { label: string; items: { message: Message; showGap: boolean }[] }>();
  for (const { message, showGap } of pairs) {
    const d = message.created_at ? new Date(message.created_at) : null;
    const key = d ? `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}` : "unknown";
    const dayLabel = d
      ? d.toLocaleDateString(locale, { weekday: "short", month: "short", day: "numeric" })
      : "Unknown date";
    if (!byKey.has(key)) {
      byKey.set(key, { label: dayLabel, items: [] });
    }
    byKey.get(key)!.items.push({ message, showGap });
  }
  return [...byKey.entries()].map(([dayKey, v]) => ({
    dayKey,
    dayLabel: v.label,
    items: v.items,
  }));
}

/** One-line preview for packet list / search (read-only). */
export function operatorInboxPacketPreviewSummary(packet: {
  stitched_content: unknown;
  fragment_count: number;
}): string {
  const sc = packet.stitched_content;
  if (sc && typeof sc === "object" && !Array.isArray(sc) && "summary" in sc) {
    const s = (sc as { summary?: unknown }).summary;
    if (typeof s === "string" && s.trim()) return s;
  }
  if (typeof sc === "string" && sc.trim()) return sc.trim().slice(0, 80);
  return `${packet.fragment_count} messages`;
}
