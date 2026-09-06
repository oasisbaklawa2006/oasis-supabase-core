/**
 * Canonical hash of protected media-archive binary entries (excludes _chat.txt).
 * Sorted entry manifest: name\x1fsize\x1fcontentSha256 per line, joined \x1e.
 */
import { sha256Hex } from "../whatsapp-stage2-historical/parse_export.ts";
import { extractZipEntryBytes, listZipEntries } from "./media_pairing.ts";

async function sha256HexBytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const CHAT_ENTRY = "_chat.txt";
const MACOSX_PREFIX = "__MACOSX/";

function isMediaBinaryEntry(name: string): boolean {
  if (name === CHAT_ENTRY) return false;
  if (name.startsWith(MACOSX_PREFIX)) return false;
  if (name.endsWith("/")) return false;
  return true;
}

export async function computeCanonicalMediaArchiveContentHash(
  zipPath: string,
): Promise<string> {
  const entries = (await listZipEntries(zipPath))
    .filter((entry) => isMediaBinaryEntry(entry.name))
    .sort((a, b) => a.name.localeCompare(b.name));

  const lines: string[] = [];
  for (const entry of entries) {
    const bytes = await extractZipEntryBytes(zipPath, entry.name);
    const contentHash = await sha256HexBytes(bytes);
    lines.push(`${entry.name}\x1f${entry.size}\x1f${contentHash}`);
  }
  return await sha256Hex(lines.join("\x1e"));
}

export async function countMediaBinaryEntries(zipPath: string): Promise<number> {
  const entries = await listZipEntries(zipPath);
  return entries.filter((entry) => isMediaBinaryEntry(entry.name)).length;
}
