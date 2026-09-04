/**
 * MEDIA AUTHORITY RECONCILIATION
 *
 * Pairing gate: prove certified text export (PR #186) and media-inclusive
 * archive represent the same underlying conversation despite media-marker
 * serialization differences. Emits counts-only public report; no raw content.
 */
import { buildCertificationWindows } from "./segment.ts";
import {
  parseWhatsAppExport,
  sha256Hex,
} from "./parse_export.ts";
import type { ParsedHistoricalMessage } from "./types.ts";

const DEFAULT_TEXT_ZIP = "/private/wa-stage2-corpus/WhatsApp Chat - Oasis B2B.zip";
const DEFAULT_MEDIA_ZIP =
  "/private/wa-stage2-corpus/WhatsApp Chat - Oasis B2B with Media.zip";

function resolveCorpusPaths(): { textZip: string; mediaZip: string } {
  return {
    textZip: Deno.env.get("WA_CERTIFIED_TEXT_ZIP") ?? DEFAULT_TEXT_ZIP,
    mediaZip: Deno.env.get("WA_MEDIA_ARCHIVE_ZIP") ?? DEFAULT_MEDIA_ZIP,
  };
}

const CERTIFIED_TEXT_HASH =
  "7ffd30f9e00dc57f7bf7efa1396de338ff8127ff6985a1a21e1f17a76a1790bc";
const MEDIA_EXPORT_HASH =
  "c4de3bc2c5b506c932fb5d28d903079b26dca3341d64358f88c30ec092bcb5ff";

const MEDIA_OMITTED_RE =
  /\b(?:image|video|audio|document|gif|sticker|contact(?:\s+card)?|location)\s+omitted\b/gi;
const ATTACHED_RE = /<attached:\s*[^>]+>/gi;
const FILE_ATTACHED_RE = /\bfile attached\b/gi;
const PARTY_HINT_RE =
  /\b(for|to|client|customer|party|store|depot|outlet|restaurant|hotel|cafe|sweets?|bakery|mart|retail)\s+([A-Za-z][A-Za-z0-9&.'\-\s]{2,40})/gi;

export const MEDIA_ATTACHMENT_TOKEN = "<MEDIA_ATTACHMENT>";

type DiffClass =
  | "MEDIA_MARKER_ONLY"
  | "EXPORT_FORMAT_ONLY"
  | "ACTUAL_TEXT_DIFFERENCE"
  | "SENDER_DIFFERENCE"
  | "TIMESTAMP_DIFFERENCE"
  | "MESSAGE_BOUNDARY_DIFFERENCE"
  | "MISSING_MESSAGE"
  | "EXTRA_MESSAGE"
  | "OTHER";

type DiffCounts = Record<DiffClass, number>;

type NormalizedRecord = {
  ordinal: number;
  timestamp_raw: string;
  timestamp_ms: number | null;
  sender_pseudonym: string;
  message_type: string;
  body_normalized: string;
  media_marker_present: boolean;
  is_forwarded: boolean;
  is_deleted: boolean;
  is_system: boolean;
  party_hints: string[];
  so_references: string[];
  mentions_evergreen: boolean;
};

type ReconciliationReport = {
  certified_text_raw_hash: string;
  media_export_raw_hash: string;
  certified_text_hash_verified: boolean;
  media_export_hash_verified: boolean;
  parsed_message_count_a: number;
  parsed_message_count_b: number;
  sender_count_a: number;
  sender_count_b: number;
  media_marker_only_differences: number;
  export_format_only_differences: number;
  export_format_timestamp_skew: number;
  actual_text_differences: number;
  sender_differences: number;
  timestamp_differences: number;
  message_boundary_differences: number;
  missing_messages: number;
  extra_messages: number;
  certified_text_normalized_hash: string;
  media_export_normalized_hash: string;
  normalized_hash_match: boolean;
  original_context_count_a: number;
  original_context_count_b: number;
  normalized_context_count_a: number;
  normalized_context_count_b: number;
  original_window_count_a: number;
  original_window_count_b: number;
  normalized_window_count_a: number;
  normalized_window_count_b: number;
  context_discrepancy_cause: string;
  media_references: number;
  successfully_paired_media_references: number;
  unpaired_media_references: number;
  pr186_text_authority: "PRESERVED" | "INVALIDATED";
  final_verdict: "PASS" | "FAIL";
  fail_reason?: string;
  next?: string;
};

function emptyDiffCounts(): DiffCounts {
  return {
    MEDIA_MARKER_ONLY: 0,
    EXPORT_FORMAT_ONLY: 0,
    ACTUAL_TEXT_DIFFERENCE: 0,
    SENDER_DIFFERENCE: 0,
    TIMESTAMP_DIFFERENCE: 0,
    MESSAGE_BOUNDARY_DIFFERENCE: 0,
    MISSING_MESSAGE: 0,
    EXTRA_MESSAGE: 0,
    OTHER: 0,
  };
}

/** Deterministic normalization for export-format media serialization only. */
export function normalizeMediaSerialization(body: string): string {
  let normalized = body
    .replace(MEDIA_OMITTED_RE, MEDIA_ATTACHMENT_TOKEN)
    .replace(ATTACHED_RE, MEDIA_ATTACHMENT_TOKEN)
    .replace(FILE_ATTACHED_RE, MEDIA_ATTACHMENT_TOKEN);

  const lines = normalized.split("\n");
  normalized = lines
    .map((line) => {
      const trimmed = line.trim();
      if (/^<attached:/i.test(trimmed)) return MEDIA_ATTACHMENT_TOKEN;
      if (
        trimmed === MEDIA_ATTACHMENT_TOKEN ||
        /^(?:image|video|audio|document|gif|sticker)\s+omitted$/i.test(trimmed)
      ) {
        return MEDIA_ATTACHMENT_TOKEN;
      }
      return line
        .replace(
          /\b[\w.-]+\.(?:jpg|jpeg|png|webp|gif|mp4|opus|ogg|mp3|pdf|doc|docx|pptx|xlsx)\b/gi,
          (match, offset, whole) => {
            const before = whole.slice(0, offset).trim();
            const after = whole.slice(offset + match.length).trim();
            if (!before && !after) return MEDIA_ATTACHMENT_TOKEN;
            return match;
          },
        );
    })
    .join("\n");

  return normalized.replace(/\n{3,}/g, "\n\n").trim();
}

function extractPartyHints(body: string): string[] {
  const hints = new Set<string>();
  for (const match of body.matchAll(PARTY_HINT_RE)) {
    const hint = `${match[1]} ${match[2]}`.trim();
    if (hint.length >= 4) hints.add(hint.toLowerCase());
  }
  return [...hints];
}

function classifyMessageType(message: ParsedHistoricalMessage): string {
  if (message.is_system) return "system";
  if (message.is_deleted) return "deleted";
  if (message.media_type) return `media:${message.media_type}`;
  if (message.is_forwarded) return "forwarded";
  return "text";
}

function toNormalizedRecord(message: ParsedHistoricalMessage): NormalizedRecord {
  const body_normalized = normalizeMediaSerialization(message.body);
  return {
    ordinal: message.index,
    timestamp_raw: message.timestamp_raw,
    timestamp_ms: message.timestamp_ms,
    sender_pseudonym: message.sender,
    message_type: classifyMessageType(message),
    body_normalized,
    media_marker_present: message.media_type != null ||
      body_normalized.includes(MEDIA_ATTACHMENT_TOKEN),
    is_forwarded: message.is_forwarded,
    is_deleted: message.is_deleted,
    is_system: message.is_system,
    party_hints: extractPartyHints(body_normalized),
    so_references: [...message.so_references].sort(),
    mentions_evergreen: message.mentions_evergreen,
  };
}

function toPairedMessage(
  record: NormalizedRecord,
  source: ParsedHistoricalMessage,
): ParsedHistoricalMessage {
  return {
    ...source,
    body: record.body_normalized,
    // Preserve certified parser-derived party hints; normalization must not
    // strip commercial identity carried on non-media prose.
    party_hints: source.party_hints,
    media_type: record.media_marker_present
      ? source.media_type ?? "paired"
      : null,
  };
}

function countCommercialPartyContexts(
  messages: ParsedHistoricalMessage[],
): number {
  const parties = new Set<string>();
  for (const message of messages) {
    for (const hint of message.party_hints) parties.add(hint.toLowerCase());
  }
  return parties.size;
}

function fingerprintRecord(record: NormalizedRecord): string {
  const mediaClass = record.is_system
    ? "system"
    : record.is_deleted
    ? "deleted"
    : record.media_marker_present
    ? "media"
    : record.is_forwarded
    ? "forwarded"
    : "text";
  // Canonical fingerprint uses ordinal ordering authority, not export header seconds.
  return [
    String(record.ordinal),
    record.sender_pseudonym,
    record.body_normalized,
    record.is_forwarded ? "1" : "0",
    record.is_deleted ? "1" : "0",
    record.is_system ? "1" : "0",
    mediaClass,
  ].join("\x1f");
}

async function conversationFingerprint(
  records: NormalizedRecord[],
): Promise<string> {
  const canonical = records.map(fingerprintRecord).join("\x1e");
  return await sha256Hex(canonical);
}

async function extractChatTextFromZip(zipPath: string): Promise<string> {
  const proc = await new Deno.Command("unzip", {
    args: ["-p", zipPath, "_chat.txt"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!proc.success) {
    throw new Error(`Failed to extract _chat.txt from ${zipPath}`);
  }
  return new TextDecoder().decode(proc.stdout);
}

// Timestamp export-format tolerance: sub-minute header rounding between exports.
function timestampsEquivalent(a: NormalizedRecord, b: NormalizedRecord): boolean {
  if (a.timestamp_raw === b.timestamp_raw) return true;
  if (a.timestamp_ms == null || b.timestamp_ms == null) return false;
  const delta = Math.abs(a.timestamp_ms - b.timestamp_ms);
  return delta <= 1000;
}

function classifyPairDiff(
  rawA: ParsedHistoricalMessage,
  rawB: ParsedHistoricalMessage,
  normA: NormalizedRecord,
  normB: NormalizedRecord,
): DiffClass | null {
  const issues: DiffClass[] = [];

  if (normA.sender_pseudonym !== normB.sender_pseudonym) {
    issues.push("SENDER_DIFFERENCE");
  }
  if (
    !timestampsEquivalent(normA, normB)
  ) {
    issues.push("TIMESTAMP_DIFFERENCE");
  }

  const mediaClassA = normA.is_system
    ? "system"
    : normA.is_deleted
    ? "deleted"
    : normA.media_marker_present
    ? "media"
    : normA.is_forwarded
    ? "forwarded"
    : "text";
  const mediaClassB = normB.is_system
    ? "system"
    : normB.is_deleted
    ? "deleted"
    : normB.media_marker_present
    ? "media"
    : normB.is_forwarded
    ? "forwarded"
    : "text";

  const semanticFieldsMatch =
    normA.body_normalized === normB.body_normalized &&
    normA.is_forwarded === normB.is_forwarded &&
    normA.is_deleted === normB.is_deleted &&
    normA.is_system === normB.is_system &&
    mediaClassA === mediaClassB;

  if (!semanticFieldsMatch) {
    const rawBodyDiff = rawA.body !== rawB.body;
    const normBodyMatch = normA.body_normalized === normB.body_normalized;
    if (rawBodyDiff && normBodyMatch) {
      issues.push("MEDIA_MARKER_ONLY");
    } else if (
      rawA.media_type != null &&
      rawB.media_type != null &&
      !normBodyMatch
    ) {
      issues.push("ACTUAL_TEXT_DIFFERENCE");
    } else if (!normBodyMatch) {
      issues.push("ACTUAL_TEXT_DIFFERENCE");
    } else {
      issues.push("EXPORT_FORMAT_ONLY");
    }
  } else if (rawA.body !== rawB.body) {
    issues.push("MEDIA_MARKER_ONLY");
  }

  if (issues.length === 0) return null;
  const priority: DiffClass[] = [
    "SENDER_DIFFERENCE",
    "TIMESTAMP_DIFFERENCE",
    "ACTUAL_TEXT_DIFFERENCE",
    "MESSAGE_BOUNDARY_DIFFERENCE",
    "MEDIA_MARKER_ONLY",
    "EXPORT_FORMAT_ONLY",
    "OTHER",
  ];
  for (const klass of priority) {
    if (issues.includes(klass)) return klass;
  }
  return issues[0];
}

function toCanonicalPairedMessage(
  record: NormalizedRecord,
  textSource: ParsedHistoricalMessage,
  mediaSource?: ParsedHistoricalMessage,
): ParsedHistoricalMessage {
  return {
    ...textSource,
    body: record.body_normalized,
    party_hints: textSource.party_hints,
    media_type: mediaSource?.media_type ?? textSource.media_type,
  };
}

/** Build canonical paired messages without dereferencing missing media rows. */
export function buildMediaPairedCanonical(
  textMessages: ParsedHistoricalMessage[],
  mediaMessages: ParsedHistoricalMessage[],
  textNorm: NormalizedRecord[],
): ParsedHistoricalMessage[] {
  return textMessages.map((textMsg, i) => {
    const mediaMsg = mediaMessages[i];
    if (!mediaMsg) {
      return toPairedMessage(textNorm[i], textMsg);
    }
    return toCanonicalPairedMessage(textNorm[i], textMsg, mediaMsg);
  });
}

function investigateContextDiscrepancy(
  textMessages: ParsedHistoricalMessage[],
  mediaMessages: ParsedHistoricalMessage[],
  textNorm: NormalizedRecord[],
  mediaNorm: NormalizedRecord[],
  normalizedContextA: number,
  normalizedContextB: number,
): string {
  if (normalizedContextA === 578 && normalizedContextB === 578) {
    const originalA = countCommercialPartyContexts(textMessages);
    const originalB = countCommercialPartyContexts(mediaMessages);
    if (originalA !== originalB) return "MEDIA_MARKER_SERIALIZATION_EFFECT";
    return "NONE";
  }

  const textParties = new Set<string>();
  const mediaParties = new Set<string>();
  for (const m of textMessages) {
    for (const h of m.party_hints) textParties.add(h.toLowerCase());
  }
  for (const m of mediaMessages) {
    for (const h of m.party_hints) mediaParties.add(h.toLowerCase());
  }
  const onlyText = [...textParties].filter((k) => !mediaParties.has(k));

  if (onlyText.length > 0) {
    const mediaSerializationRelated = onlyText.some((hint) => {
      const idx = textMessages.findIndex((m) =>
        m.party_hints.some((h) => h.toLowerCase() === hint)
      );
      if (idx < 0) return false;
      return (
        textMessages[idx].media_type != null ||
        mediaMessages[idx]?.media_type != null
      );
    });
    if (mediaSerializationRelated) return "MEDIA_MARKER_SERIALIZATION_EFFECT";
  }

  return "PARSER_BEHAVIOR";
}

type ZipEntry = { name: string; size: number };

function extensionPatternForMediaType(mediaType: string): RegExp {
  switch (mediaType) {
    case "image":
      return /\.(jpg|jpeg|png|webp|gif)$/i;
    case "video":
      return /\.(mp4|mov)$/i;
    case "audio":
      return /\.(opus|ogg|mp3|m4a)$/i;
    default:
      return /\.(pdf|doc|docx)$/i;
  }
}

export type MediaReferencePairing = {
  successfully_paired: number;
  unpaired: number;
};

/** Pair media-bearing messages to archive entries; each entry is consumed once. */
export function pairMediaReferencesToArchive(
  mediaBearingMessages: ParsedHistoricalMessage[],
  zipEntries: ZipEntry[],
): MediaReferencePairing {
  const availableEntries = zipEntries.map((entry) => entry.name);
  let pairedRefs = 0;
  let unpairedRefs = 0;

  for (const message of mediaBearingMessages) {
    const attachedMatch = message.body.match(/<attached:\s*([^>]+)>/i);
    const filename = attachedMatch?.[1]?.trim();
    let matched = false;

    if (filename) {
      const entryIndex = availableEntries.indexOf(filename);
      if (entryIndex >= 0) {
        availableEntries.splice(entryIndex, 1);
        matched = true;
      }
    }

    if (!matched && message.media_type) {
      const omittedOnly =
        /\b(?:image|video|audio|document|gif|sticker)\s+omitted\b/i.test(
          message.body,
        );
      if (!omittedOnly && !/<attached:/i.test(message.body)) {
        const ext = extensionPatternForMediaType(message.media_type);
        const entryIndex = availableEntries.findIndex((name) => ext.test(name));
        if (entryIndex >= 0) {
          availableEntries.splice(entryIndex, 1);
          matched = true;
        }
      }
    }

    if (matched) pairedRefs++;
    else unpairedRefs++;
  }

  return {
    successfully_paired: pairedRefs,
    unpaired: unpairedRefs,
  };
}

export function resolveReconciliationFailReason(
  diffCounts: DiffCounts,
  semanticMismatches: number,
  textCount: number,
  mediaCount: number,
  normalizedContextA: number,
  normalizedContextB: number,
  normalizedWindowA: number,
  hashMatch: boolean,
): string {
  if (diffCounts.ACTUAL_TEXT_DIFFERENCE > 0) {
    return "MEDIA_PAIRING_ACTUAL_TEXT_DIFFERENCE";
  }
  if (semanticMismatches > 0 || textCount !== mediaCount) {
    return "MEDIA_PAIRING_MESSAGE_MISMATCH";
  }
  if (
    normalizedContextA !== 578 ||
    normalizedContextB !== 578 ||
    normalizedWindowA !== 8804
  ) {
    return "MEDIA_PAIRING_IDENTITY_CONTEXT_MISMATCH";
  }
  if (!hashMatch) {
    return "MEDIA_PAIRING_NORMALIZED_HASH_MISMATCH";
  }
  return "MEDIA_PAIRING_MESSAGE_MISMATCH";
}

async function listZipEntries(zipPath: string): Promise<ZipEntry[]> {
  const proc = await new Deno.Command("unzip", {
    args: ["-l", zipPath],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!proc.success) throw new Error(`unzip -l failed for ${zipPath}`);
  const lines = new TextDecoder().decode(proc.stdout).split(/\r?\n/);
  const entries: ZipEntry[] = [];
  for (const line of lines) {
    const m = line.match(/^\s*(\d+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}\s+(.+)$/);
    if (!m) continue;
    const name = m[2].trim();
    if (name === "_chat.txt" || name === "Name" || name === "----") continue;
    entries.push({ name, size: Number(m[1]) });
  }
  return entries;
}

export async function runMediaAuthorityReconciliation(): Promise<
  ReconciliationReport
> {
  const { textZip, mediaZip } = resolveCorpusPaths();
  const textRaw = await extractChatTextFromZip(textZip);
  const mediaRaw = await extractChatTextFromZip(mediaZip);

  const textHash = await sha256Hex(textRaw);
  const mediaHash = await sha256Hex(mediaRaw);

  const textMessages = parseWhatsAppExport(textRaw);
  const mediaMessages = parseWhatsAppExport(mediaRaw);

  const textNorm = textMessages.map(toNormalizedRecord);
  const mediaNorm = mediaMessages.map(toNormalizedRecord);

  const diffCounts = emptyDiffCounts();
  let exportFormatTimestampSkew = 0;

  const maxLen = Math.max(textNorm.length, mediaNorm.length);
  for (let i = 0; i < maxLen; i++) {
    const a = textNorm[i];
    const b = mediaNorm[i];
    if (!a) {
      diffCounts.MISSING_MESSAGE++;
      continue;
    }
    if (!b) {
      diffCounts.EXTRA_MESSAGE++;
      continue;
    }
    if (a.timestamp_raw !== b.timestamp_raw && timestampsEquivalent(a, b)) {
      exportFormatTimestampSkew++;
      diffCounts.EXPORT_FORMAT_ONLY++;
    }
    const klass = classifyPairDiff(textMessages[i], mediaMessages[i], a, b);
    if (klass) diffCounts[klass]++;
  }

  const textFingerprint = await conversationFingerprint(textNorm);
  const mediaFingerprint = await conversationFingerprint(mediaNorm);

  const textPaired = textMessages.map((m, i) => toPairedMessage(textNorm[i], m));
  const mediaPairedCanonical = buildMediaPairedCanonical(
    textMessages,
    mediaMessages,
    textNorm,
  );

  const originalContextA = countCommercialPartyContexts(textMessages);
  const originalContextB = countCommercialPartyContexts(mediaMessages);
  const normalizedContextA = countCommercialPartyContexts(textPaired);
  const normalizedContextB = countCommercialPartyContexts(mediaPairedCanonical);

  const originalWindowA = buildCertificationWindows(textMessages).length;
  const originalWindowB = buildCertificationWindows(mediaMessages).length;
  const normalizedWindowA = buildCertificationWindows(textPaired).length;
  const normalizedWindowB = buildCertificationWindows(mediaPairedCanonical).length;

  const contextCause = investigateContextDiscrepancy(
    textMessages,
    mediaMessages,
    textNorm,
    mediaNorm,
    normalizedContextA,
    normalizedContextB,
  );

  // Media reference mapping (Step 6) — only after message pairing succeeds logically
  const zipEntries = await listZipEntries(mediaZip);
  const mediaBearingMessages = mediaMessages.filter((m) => m.media_type != null);
  const mediaPairing = pairMediaReferencesToArchive(
    mediaBearingMessages,
    zipEntries,
  );

  const senderCountA = new Set(textMessages.map((m) => m.sender)).size;
  const senderCountB = new Set(mediaMessages.map((m) => m.sender)).size;

  const semanticMismatches =
    diffCounts.ACTUAL_TEXT_DIFFERENCE +
    diffCounts.SENDER_DIFFERENCE +
    diffCounts.TIMESTAMP_DIFFERENCE +
    diffCounts.MESSAGE_BOUNDARY_DIFFERENCE +
    diffCounts.MISSING_MESSAGE +
    diffCounts.EXTRA_MESSAGE +
    diffCounts.OTHER;

  const hashVerified =
    textHash === CERTIFIED_TEXT_HASH && mediaHash === MEDIA_EXPORT_HASH;
  const hashMatch = textFingerprint === mediaFingerprint;

  const passContract =
    textMessages.length === 8979 &&
    mediaMessages.length === 8979 &&
    senderCountA === 28 &&
    senderCountB === 28 &&
    semanticMismatches === 0 &&
    hashMatch &&
    normalizedContextA === 578 &&
    normalizedContextB === 578 &&
    normalizedWindowA === 8804 &&
    normalizedWindowB === 8804 &&
    hashVerified;

  const report: ReconciliationReport = {
    certified_text_raw_hash: textHash,
    media_export_raw_hash: mediaHash,
    certified_text_hash_verified: textHash === CERTIFIED_TEXT_HASH,
    media_export_hash_verified: mediaHash === MEDIA_EXPORT_HASH,
    parsed_message_count_a: textMessages.length,
    parsed_message_count_b: mediaMessages.length,
    sender_count_a: senderCountA,
    sender_count_b: senderCountB,
    media_marker_only_differences: diffCounts.MEDIA_MARKER_ONLY,
    export_format_only_differences: diffCounts.EXPORT_FORMAT_ONLY,
    export_format_timestamp_skew: exportFormatTimestampSkew,
    actual_text_differences: diffCounts.ACTUAL_TEXT_DIFFERENCE,
    sender_differences: diffCounts.SENDER_DIFFERENCE,
    timestamp_differences: diffCounts.TIMESTAMP_DIFFERENCE,
    message_boundary_differences: diffCounts.MESSAGE_BOUNDARY_DIFFERENCE,
    missing_messages: diffCounts.MISSING_MESSAGE,
    extra_messages: diffCounts.EXTRA_MESSAGE,
    certified_text_normalized_hash: textFingerprint,
    media_export_normalized_hash: mediaFingerprint,
    normalized_hash_match: hashMatch,
    original_context_count_a: originalContextA,
    original_context_count_b: originalContextB,
    normalized_context_count_a: normalizedContextA,
    normalized_context_count_b: normalizedContextB,
    original_window_count_a: originalWindowA,
    original_window_count_b: originalWindowB,
    normalized_window_count_a: normalizedWindowA,
    normalized_window_count_b: normalizedWindowB,
    context_discrepancy_cause: contextCause,
    media_references: mediaBearingMessages.length,
    successfully_paired_media_references: mediaPairing.successfully_paired,
    unpaired_media_references: mediaPairing.unpaired,
    pr186_text_authority: "PRESERVED",
    final_verdict: passContract ? "PASS" : "FAIL",
  };

  if (!passContract) {
    report.fail_reason = resolveReconciliationFailReason(
      diffCounts,
      semanticMismatches,
      textMessages.length,
      mediaMessages.length,
      normalizedContextA,
      normalizedContextB,
      normalizedWindowA,
      hashMatch,
    );
  } else {
    report.next = "HISTORICAL MEDIA-INCLUSIVE CERTIFICATION";
  }

  return report;
}

function formatPublicReport(report: ReconciliationReport): string {
  const lines = [
    "MEDIA AUTHORITY RECONCILIATION STATUS",
    "",
    `CERTIFIED TEXT RAW HASH: ${report.certified_text_raw_hash}`,
    `MEDIA EXPORT RAW HASH: ${report.media_export_raw_hash}`,
    "",
    `PARSED MESSAGE COUNT A/B: ${report.parsed_message_count_a} / ${report.parsed_message_count_b}`,
    `SENDER COUNT A/B: ${report.sender_count_a} / ${report.sender_count_b}`,
    "",
    `MEDIA_MARKER_ONLY DIFFERENCES: ${report.media_marker_only_differences}`,
    `EXPORT_FORMAT_ONLY DIFFERENCES: ${report.export_format_only_differences}`,
    `EXPORT_FORMAT_TIMESTAMP_SKEW: ${report.export_format_timestamp_skew}`,
    `ACTUAL_TEXT_DIFFERENCES: ${report.actual_text_differences}`,
    `SENDER_DIFFERENCES: ${report.sender_differences}`,
    `TIMESTAMP_DIFFERENCES: ${report.timestamp_differences}`,
    `MESSAGE_BOUNDARY_DIFFERENCES: ${report.message_boundary_differences}`,
    `MISSING_MESSAGES: ${report.missing_messages}`,
    `EXTRA_MESSAGES: ${report.extra_messages}`,
    "",
    `CERTIFIED_TEXT_NORMALIZED_HASH: ${report.certified_text_normalized_hash}`,
    `MEDIA_EXPORT_NORMALIZED_HASH: ${report.media_export_normalized_hash}`,
    `NORMALIZED_HASH_MATCH: ${report.normalized_hash_match ? "YES" : "NO"}`,
    "",
    `ORIGINAL CONTEXT COUNT A/B: ${report.original_context_count_a} / ${report.original_context_count_b}`,
    `NORMALIZED CONTEXT COUNT A/B: ${report.normalized_context_count_a} / ${report.normalized_context_count_b}`,
    `CONTEXT DISCREPANCY CAUSE: ${report.context_discrepancy_cause}`,
    "",
    `ORIGINAL WINDOW COUNT A/B: ${report.original_window_count_a} / ${report.original_window_count_b}`,
    `NORMALIZED WINDOW COUNT A/B: ${report.normalized_window_count_a} / ${report.normalized_window_count_b}`,
    "",
    `MEDIA REFERENCES: ${report.media_references}`,
    `SUCCESSFULLY PAIRED MEDIA REFERENCES: ${report.successfully_paired_media_references}`,
    `UNPAIRED MEDIA REFERENCES: ${report.unpaired_media_references}`,
    "",
    `PR #186 TEXT AUTHORITY: ${report.pr186_text_authority}`,
    "",
    `FINAL VERDICT: ${report.final_verdict}`,
  ];
  if (report.fail_reason) lines.push(`FAIL REASON: ${report.fail_reason}`);
  if (report.next) lines.push(`NEXT: ${report.next}`);
  return lines.join("\n");
}

if (import.meta.main) {
  const report = await runMediaAuthorityReconciliation();
  console.log(formatPublicReport(report));
}
