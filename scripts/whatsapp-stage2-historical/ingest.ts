import { parseWhatsAppExport, sha256Hex } from "./parse_export.ts";
import type { IngestResult, ParsedHistoricalMessage } from "./types.ts";

const DEFAULT_CORPUS_CANDIDATES = [
  "/secure/wa-stage2-corpus/WhatsApp Chat - Oasis B2B 2.zip",
  "/secure/wa-stage2-corpus/_chat.txt",
  "protected-corpus/oasis-b2b-2/WhatsApp Chat - Oasis B2B 2.zip",
  "protected-corpus/oasis-b2b-2/_chat.txt",
];

export async function resolveCorpusPath(
  explicit?: string,
): Promise<string> {
  const candidates = [
    explicit,
    Deno.env.get("WA_PROTECTED_CORPUS_PATH"),
    ...DEFAULT_CORPUS_CANDIDATES,
  ].filter((value): value is string => Boolean(value?.trim()));

  for (const candidate of candidates) {
    try {
      await Deno.stat(candidate);
      return candidate;
    } catch {
      // try next
    }
  }

  throw new Error(
    "Authorized corpus not found. Place 'WhatsApp Chat - Oasis B2B 2.zip' or extracted '_chat.txt' at " +
      "/secure/wa-stage2-corpus/ and set WA_PROTECTED_CORPUS_PATH.",
  );
}

async function readBytes(path: string): Promise<Uint8Array> {
  return await Deno.readFile(path);
}

async function extractChatTextFromZip(zipPath: string): Promise<string> {
  const proc = new Deno.Command("unzip", {
    args: ["-p", zipPath, "_chat.txt"],
    stdout: "piped",
    stderr: "piped",
  }).output();
  const result = await proc;
  if (!result.success) {
    const tempDir = await Deno.makeTempDir({ prefix: "wa-stage2-" });
    try {
      const extract = await new Deno.Command("unzip", {
        args: ["-o", zipPath, "_chat.txt", "-d", tempDir],
        stdout: "piped",
        stderr: "piped",
      }).output();
      if (!extract.success) {
        throw new Error(
          `Failed to extract _chat.txt from zip (${zipPath})`,
        );
      }
      return await Deno.readTextFile(`${tempDir}/_chat.txt`);
    } finally {
      await Deno.remove(tempDir, { recursive: true });
    }
  }
  return new TextDecoder().decode(result.stdout);
}

async function loadExportText(path: string): Promise<{ text: string; bytes: number }> {
  const lower = path.toLowerCase();
  if (lower.endsWith(".zip")) {
    const bytes = await readBytes(path);
    const text = await extractChatTextFromZip(path);
    return { text, bytes: bytes.byteLength };
  }
  const bytes = await readBytes(path);
  return { text: new TextDecoder().decode(bytes), bytes: bytes.byteLength };
}

function dateRange(messages: ParsedHistoricalMessage[]): {
  start: string | null;
  end: string | null;
} {
  const dated = messages.filter((m) => m.timestamp_ms != null);
  if (!dated.length) return { start: null, end: null };
  dated.sort((a, b) => (a.timestamp_ms ?? 0) - (b.timestamp_ms ?? 0));
  return {
    start: dated[0].timestamp_raw,
    end: dated[dated.length - 1].timestamp_raw,
  };
}

function countCommercialPartyContexts(messages: ParsedHistoricalMessage[]): number {
  const parties = new Set<string>();
  for (const message of messages) {
    for (const hint of message.party_hints) parties.add(hint.toLowerCase());
  }
  return parties.size;
}

export async function ingestHistoricalCorpus(
  explicitPath?: string,
): Promise<IngestResult> {
  const source_path = await resolveCorpusPath(explicitPath);
  const { text, bytes } = await loadExportText(source_path);
  const messages = parseWhatsAppExport(text);
  const corpus_hash = await sha256Hex(text);
  const senders = new Set(messages.map((m) => m.sender));
  return {
    source_path,
    corpus_bytes: bytes,
    corpus_hash,
    messages,
    date_range: dateRange(messages),
    unique_senders: senders.size,
    commercial_party_contexts: countCommercialPartyContexts(messages),
  };
}

export function summarizeIngest(ingest: IngestResult): Record<string, unknown> {
  return {
    source_path: ingest.source_path,
    corpus_bytes: ingest.corpus_bytes,
    corpus_hash: ingest.corpus_hash,
    parsed_message_count: ingest.messages.length,
    unique_senders: ingest.unique_senders,
    commercial_party_contexts: ingest.commercial_party_contexts,
    historical_date_range: ingest.date_range,
  };
}
