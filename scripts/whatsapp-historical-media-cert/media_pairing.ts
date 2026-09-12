import type { ParsedHistoricalMessage } from "../whatsapp-stage2-historical/types.ts";
import {
  extensionPatternForMediaType,
} from "./media_pairing_utils.ts";

export type ZipEntry = { name: string; size: number };

export type DetailedMediaPair = {
  message_index: number;
  archive_entry: string | null;
  message: ParsedHistoricalMessage;
  match_mode: "filename" | "extension_fallback" | "unmatched";
};

export async function listZipEntries(zipPath: string): Promise<ZipEntry[]> {
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

/** Pair media-bearing messages to archive entries; each entry consumed once. */
export function buildDetailedMediaPairing(
  mediaBearingMessages: ParsedHistoricalMessage[],
  zipEntries: ZipEntry[],
): DetailedMediaPair[] {
  const availableEntries = zipEntries.map((entry) => entry.name);
  const pairs: DetailedMediaPair[] = [];

  for (const message of mediaBearingMessages) {
    const attachedMatch = message.body.match(/<attached:\s*([^>]+)>/i);
    const filename = attachedMatch?.[1]?.trim();
    let matchedEntry: string | null = null;

    let matchMode: DetailedMediaPair["match_mode"] = "unmatched";

    if (filename) {
      const entryIndex = availableEntries.indexOf(filename);
      if (entryIndex >= 0) {
        matchedEntry = availableEntries.splice(entryIndex, 1)[0];
        matchMode = "filename";
      }
    }

    if (!matchedEntry && message.media_type) {
      const omittedOnly =
        /\b(?:image|video|audio|document|gif|sticker)\s+omitted\b/i.test(
          message.body,
        );
      if (!omittedOnly && !/<attached:/i.test(message.body)) {
        const ext = extensionPatternForMediaType(message.media_type);
        const entryIndex = availableEntries.findIndex((name) => ext.test(name));
        if (entryIndex >= 0) {
          matchedEntry = availableEntries.splice(entryIndex, 1)[0];
          matchMode = "extension_fallback";
        }
      }
    }

    pairs.push({
      message_index: message.index,
      archive_entry: matchedEntry,
      message,
      match_mode: matchedEntry ? matchMode : "unmatched",
    });
  }

  return pairs;
}

function escapeZipEntryName(entryName: string): string {
  return entryName.replace(/([\\*?\[\]])/g, "\\$1");
}

export async function extractZipEntryBytes(
  zipPath: string,
  entryName: string,
): Promise<Uint8Array> {
  const proc = await new Deno.Command("unzip", {
    args: ["-p", zipPath, escapeZipEntryName(entryName)],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!proc.success) {
    throw new Error(`Failed to extract ${entryName} from archive`);
  }
  return proc.stdout;
}
