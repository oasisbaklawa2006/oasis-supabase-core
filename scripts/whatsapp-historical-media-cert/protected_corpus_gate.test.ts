import {
  BLOCKED_VERDICT,
  CERTIFIED_TEXT_HASH,
  MEDIA_AUTHORITY,
  MEDIA_SIDECAR_HASH,
  verifyProtectedCorpusGate,
} from "./protected_corpus_gate.ts";

Deno.test("protected corpus gate fails closed when September mounts are absent", async () => {
  const gate = await verifyProtectedCorpusGate({
    textZip: "/tmp/wa-hist-media-cert-missing-text.zip",
    mediaZip: "/tmp/wa-hist-media-cert-missing-media.zip",
  });
    if (gate.status !== "BLOCKED") {
      throw new Error(`expected BLOCKED, got ${gate.status}`);
    }
    if (gate.verdict !== BLOCKED_VERDICT) {
      throw new Error(`expected ${BLOCKED_VERDICT}, got ${gate.verdict}`);
    }
    if (gate.missing_paths.length !== 2) {
      throw new Error(
        `expected two missing paths, got ${gate.missing_paths.length}`,
      );
    }
});

Deno.test("media authority constants match PR #188 pairing gate", () => {
  if (MEDIA_AUTHORITY.media_references !== 2441) {
    throw new Error("media_references regression");
  }
  if (MEDIA_AUTHORITY.paired_references !== 2376) {
    throw new Error("paired_references regression");
  }
  if (MEDIA_AUTHORITY.unpaired_detections !== 65) {
    throw new Error("unpaired_detections regression");
  }
});

Deno.test("certified authority hashes are pinned", () => {
  if (
    CERTIFIED_TEXT_HASH !==
    "7ffd30f9e00dc57f7bf7efa1396de338ff8127ff6985a1a21e1f17a76a1790bc"
  ) {
    throw new Error("text authority hash regression");
  }
  if (
    MEDIA_SIDECAR_HASH !==
    "c4de3bc2c5b506c932fb5d28d903079b26dca3341d64358f88c30ec092bcb5ff"
  ) {
    throw new Error("media sidecar hash regression");
  }
});
