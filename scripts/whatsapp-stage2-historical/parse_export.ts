import type { ParsedHistoricalMessage } from "./types.ts";

const MESSAGE_HEADER_RE =
  /^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?)\]\s([^:]+):\s([\s\S]*)$/;

/** WhatsApp system notices omit the `sender:` segment (e.g. encryption banner). */
const SYSTEM_LINE_RE =
  /^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?)\]\s(.+)$/;

const SO_REF_RE = /\bSO[\s#:-]*(\d{4,8})\b/gi;
const PARTY_HINT_RE =
  /\b(for|to|client|customer|party|store|depot|outlet|restaurant|hotel|cafe|sweets?|bakery|mart|retail)\s+([A-Za-z][A-Za-z0-9&.'\-\s]{2,40})/gi;

export function detectMediaType(body: string): string | null {
  const lower = body.toLowerCase();
  if (/image omitted|photo omitted|sticker omitted|<attached:|file attached|\.jpg|\.jpeg|\.png|\.webp/.test(lower)) {
    return "image";
  }
  if (/video omitted|\.mp4/.test(lower)) return "video";
  if (/audio omitted|\.opus|\.ogg|\.mp3/.test(lower)) return "audio";
  if (/document omitted|\.pdf|\.doc/.test(lower)) return "document";
  return null;
}

export function isSystemMessage(body: string): boolean {
  const lower = body.toLowerCase();
  return (
    lower.includes("messages and calls are end-to-end encrypted") ||
    lower.includes("created group") ||
    lower.includes("changed the subject") ||
    lower.includes("changed this group's icon") ||
    lower.includes("you were added") ||
    lower.includes("security code changed") ||
    lower.includes("joined using this group's invite link")
  );
}

export function isDeletedMessage(body: string): boolean {
  const lower = body.toLowerCase();
  return lower.includes("this message was deleted") ||
    lower.includes("you deleted this message");
}

function parseTimestampMs(datePart: string, timePart: string): number | null {
  const dm = datePart.match(/^(\d{1,2})\/(\d{1,2})\/(\d{2,4})$/);
  if (!dm) return null;
  const day = Number(dm[1]);
  const month = Number(dm[2]) - 1;
  let year = Number(dm[3]);
  if (year < 100) year += 2000;
  const tm = timePart.trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$/i);
  if (!tm) return null;
  let hour = Number(tm[1]);
  const minute = Number(tm[2]);
  const second = tm[3] ? Number(tm[3]) : 0;
  const ampm = tm[4]?.toUpperCase();
  if (ampm === "PM" && hour < 12) hour += 12;
  if (ampm === "AM" && hour === 12) hour = 0;
  const dt = new Date(Date.UTC(year, month, day, hour, minute, second));
  return Number.isNaN(dt.getTime()) ? null : dt.getTime();
}

function extractSoReferences(body: string): string[] {
  const refs = new Set<string>();
  for (const match of body.matchAll(SO_REF_RE)) {
    refs.add(`SO-${match[1]}`);
  }
  return [...refs];
}

function extractPartyHints(body: string): string[] {
  const hints = new Set<string>();
  for (const match of body.matchAll(PARTY_HINT_RE)) {
    const hint = `${match[1]} ${match[2]}`.trim();
    if (hint.length >= 4) hints.add(hint);
  }
  return [...hints];
}

export function parseWhatsAppExport(text: string): ParsedHistoricalMessage[] {
  const lines = text.replace(/\u200e/g, "").split(/\r?\n/);
  const messages: ParsedHistoricalMessage[] = [];
  let current: ParsedHistoricalMessage | null = null;
  let index = 0;

  for (const line of lines) {
    const match = line.match(MESSAGE_HEADER_RE);
    if (match) {
      if (current) messages.push(current);
      index += 1;
      const body = match[4].trim();
      const timestamp_raw = `${match[1]} ${match[2]}`;
      current = {
        index,
        timestamp_raw,
        timestamp_ms: parseTimestampMs(match[1], match[2]),
        sender: match[3].trim(),
        body,
        is_forwarded: /^forwarded message/i.test(body),
        is_deleted: isDeletedMessage(body),
        is_system: isSystemMessage(body),
        media_type: detectMediaType(body),
        so_references: extractSoReferences(body),
        party_hints: extractPartyHints(body),
        mentions_evergreen: /\bevergreen\b/i.test(body),
      };
      continue;
    }

    const systemMatch = line.match(SYSTEM_LINE_RE);
    if (systemMatch) {
      if (current) messages.push(current);
      index += 1;
      const body = systemMatch[3].trim();
      const timestamp_raw = `${systemMatch[1]} ${systemMatch[2]}`;
      current = {
        index,
        timestamp_raw,
        timestamp_ms: parseTimestampMs(systemMatch[1], systemMatch[2]),
        sender: "System",
        body,
        is_forwarded: false,
        is_deleted: false,
        is_system: true,
        media_type: detectMediaType(body),
        so_references: extractSoReferences(body),
        party_hints: extractPartyHints(body),
        mentions_evergreen: /\bevergreen\b/i.test(body),
      };
      continue;
    }

    if (current && line.trim()) {
      current.body = `${current.body}\n${line}`.trim();
      current.media_type = current.media_type ?? detectMediaType(current.body);
      current.is_forwarded = current.is_forwarded ||
        /^forwarded message/i.test(current.body);
      current.is_deleted = current.is_deleted || isDeletedMessage(current.body);
      current.is_system = current.is_system || isSystemMessage(current.body);
      current.so_references = extractSoReferences(current.body);
      current.party_hints = extractPartyHints(current.body);
      current.mentions_evergreen = /\bevergreen\b/i.test(current.body);
    }
  }
  if (current) messages.push(current);
  return messages;
}

export async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
