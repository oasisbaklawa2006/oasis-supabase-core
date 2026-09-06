/**
 * Fail-closed gate for historical media-inclusive certification.
 * Verifies September protected corpus mounts and authority hashes before
 * any multimodal execution. Never substitutes alternate exports.
 */
import { sha256Hex } from "../whatsapp-stage2-historical/parse_export.ts";
import {
  CERTIFIED_MEDIA_PAIRED,
  CERTIFIED_MEDIA_REFERENCES,
  CERTIFIED_MEDIA_UNPAIRED,
} from "../whatsapp-stage2-historical/media_authority_reconciliation.ts";
import {
  computeCanonicalMediaArchiveContentHash,
  countMediaBinaryEntries,
} from "./media_archive_content_hash.ts";

export const CERTIFIED_TEXT_HASH =
  "7ffd30f9e00dc57f7bf7efa1396de338ff8127ff6985a1a21e1f17a76a1790bc";
export const MEDIA_SIDECAR_HASH =
  "c4de3bc2c5b506c932fb5d28d903079b26dca3341d64358f88c30ec092bcb5ff";
export const CERTIFIED_MEDIA_ARCHIVE_BYTES = 684_210_625;
/** Pin via `deno run ... protected_corpus_gate.ts --print-media-content-hash` on protected mount. */
export const CERTIFIED_MEDIA_CONTENT_HASH: string | null = null;
export const CERTIFIED_MEDIA_BINARY_ENTRY_COUNT = CERTIFIED_MEDIA_REFERENCES;

export const EXPECTED_MESSAGES = 8979;
export const EXPECTED_SENDERS = 28;
export const EXPECTED_NORMALIZED_CONTEXTS = 578;
export const EXPECTED_V3_WINDOWS = 8804;

export const BLOCKED_VERDICT = "PROTECTED_SEPTEMBER_MEDIA_SIDECAR_REQUIRED";

const DEFAULT_TEXT_ZIP =
  "/private/wa-stage2-corpus/WhatsApp Chat - Oasis B2B.zip";
const DEFAULT_MEDIA_ZIP =
  "/private/wa-stage2-corpus/WhatsApp Chat - Oasis B2B with Media.zip";

export type CorpusPaths = {
  textZip: string;
  mediaZip: string;
};

export type ProtectedCorpusGateResult =
  | {
      status: "READY";
      paths: CorpusPaths;
      text_hash_verified: true;
      media_hash_verified: true;
      media_content_hash: string;
      media_content_hash_verified: boolean;
      media_binary_entry_count: number;
    }
  | {
      status: "BLOCKED";
      verdict: typeof BLOCKED_VERDICT;
      missing_paths: string[];
      reason: string;
    };

export function resolveCorpusPaths(): CorpusPaths {
  return {
    textZip: Deno.env.get("WA_CERTIFIED_TEXT_ZIP") ?? DEFAULT_TEXT_ZIP,
    mediaZip: Deno.env.get("WA_MEDIA_ARCHIVE_ZIP") ?? DEFAULT_MEDIA_ZIP,
  };
}

async function fileExists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path);
    return true;
  } catch {
    return false;
  }
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

export async function verifyProtectedCorpusGate(
  pathsOverride?: CorpusPaths,
): Promise<ProtectedCorpusGateResult> {
  const paths = pathsOverride ?? resolveCorpusPaths();
  const missing: string[] = [];
  if (!(await fileExists(paths.textZip))) missing.push(paths.textZip);
  if (!(await fileExists(paths.mediaZip))) missing.push(paths.mediaZip);

  if (missing.length > 0) {
    return {
      status: "BLOCKED",
      verdict: BLOCKED_VERDICT,
      missing_paths: missing,
      reason:
        "September protected text export and media-inclusive archive must be mounted outside Git. Do not substitute the June archive or any other export.",
    };
  }

  const textRaw = await extractChatTextFromZip(paths.textZip);
  const mediaRaw = await extractChatTextFromZip(paths.mediaZip);
  const textHash = await sha256Hex(textRaw);
  const mediaHash = await sha256Hex(mediaRaw);
  const mediaArchiveBytes = (await Deno.stat(paths.mediaZip)).size;

  if (textHash !== CERTIFIED_TEXT_HASH || mediaHash !== MEDIA_SIDECAR_HASH) {
    return {
      status: "BLOCKED",
      verdict: BLOCKED_VERDICT,
      missing_paths: [],
      reason:
        "Mounted corpus hashes do not match certified September authorities. Expected text and media sidecar hashes from PR #186 / PR #188.",
    };
  }

  if (mediaArchiveBytes !== CERTIFIED_MEDIA_ARCHIVE_BYTES) {
    return {
      status: "BLOCKED",
      verdict: BLOCKED_VERDICT,
      missing_paths: [],
      reason:
        `Mounted media archive byte size (${mediaArchiveBytes}) does not match certified September authority (${CERTIFIED_MEDIA_ARCHIVE_BYTES}).`,
    };
  }

  const mediaBinaryEntryCount = await countMediaBinaryEntries(paths.mediaZip);
  if (mediaBinaryEntryCount !== CERTIFIED_MEDIA_BINARY_ENTRY_COUNT) {
    return {
      status: "BLOCKED",
      verdict: BLOCKED_VERDICT,
      missing_paths: [],
      reason:
        `Mounted media archive binary entry count (${mediaBinaryEntryCount}) does not match certified September authority (${CERTIFIED_MEDIA_BINARY_ENTRY_COUNT}).`,
    };
  }

  const mediaContentHash = await computeCanonicalMediaArchiveContentHash(
    paths.mediaZip,
  );
  const mediaContentHashVerified = CERTIFIED_MEDIA_CONTENT_HASH !== null &&
    mediaContentHash === CERTIFIED_MEDIA_CONTENT_HASH;
  if (CERTIFIED_MEDIA_CONTENT_HASH !== null && !mediaContentHashVerified) {
    return {
      status: "BLOCKED",
      verdict: BLOCKED_VERDICT,
      missing_paths: [],
      reason:
        "Mounted media archive canonical content hash does not match certified September authority.",
    };
  }

  return {
    status: "READY",
    paths,
    text_hash_verified: true,
    media_hash_verified: true,
    media_content_hash: mediaContentHash,
    media_content_hash_verified: mediaContentHashVerified,
    media_binary_entry_count: mediaBinaryEntryCount,
  };
}

export const MEDIA_AUTHORITY = {
  media_references: CERTIFIED_MEDIA_REFERENCES,
  paired_references: CERTIFIED_MEDIA_PAIRED,
  unpaired_detections: CERTIFIED_MEDIA_UNPAIRED,
};

if (import.meta.main) {
  const printContentHash = Deno.args.includes("--print-media-content-hash");
  const gate = await verifyProtectedCorpusGate();
  if (gate.status === "BLOCKED") {
    console.error(gate.verdict);
    console.error(gate.reason);
    for (const path of gate.missing_paths) {
      console.error(`MISSING: ${path}`);
    }
    Deno.exit(1);
  }
  console.log("PROTECTED_CORPUS_GATE: READY");
  console.log(`TEXT_HASH: ${CERTIFIED_TEXT_HASH}`);
  console.log(`MEDIA_SIDECAR_HASH: ${MEDIA_SIDECAR_HASH}`);
  console.log(`MEDIA_CONTENT_HASH: ${gate.media_content_hash}`);
  console.log(
    `MEDIA_CONTENT_HASH_VERIFIED: ${gate.media_content_hash_verified ? "YES" : "NO"}`,
  );
  console.log(`MEDIA_BINARY_ENTRY_COUNT: ${gate.media_binary_entry_count}`);
  if (printContentHash) {
    console.log(`PIN_CERTIFIED_MEDIA_CONTENT_HASH=${gate.media_content_hash}`);
  }
  console.log(
    `MEDIA_AUTHORITY: ${CERTIFIED_MEDIA_REFERENCES} refs / ${CERTIFIED_MEDIA_PAIRED} paired / ${CERTIFIED_MEDIA_UNPAIRED} unpaired`,
  );
}
