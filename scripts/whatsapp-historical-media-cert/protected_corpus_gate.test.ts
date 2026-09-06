import {
  BLOCKED_VERDICT,
  CERTIFIED_MEDIA_ARCHIVE_BYTES,
  CERTIFIED_TEXT_HASH,
  MEDIA_AUTHORITY,
  MEDIA_SIDECAR_HASH,
  verifyProtectedCorpusGate,
} from "./protected_corpus_gate.ts";
import {
  CANONICAL_V3_CERTIFICATION_WINDOWS,
  reconcileWindowAuthority,
  SUPERSEDED_V2_CERTIFICATION_WINDOWS,
} from "./window_authority.ts";

Deno.test("window authority reconciles superseded v2 8754 against canonical v3 8804", () => {
  const reconciliation = reconcileWindowAuthority(CANONICAL_V3_CERTIFICATION_WINDOWS);
  if (reconciliation.superseded_v2_windows !== SUPERSEDED_V2_CERTIFICATION_WINDOWS) {
    throw new Error("superseded v2 window regression");
  }
  if (reconciliation.observed_v3_windows !== 8804) {
    throw new Error("canonical v3 window regression");
  }
  if (!reconciliation.reconciliation_note.includes("8,804")) {
    throw new Error("missing reconciliation note");
  }
});

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

Deno.test("certified media archive byte authority is pinned", () => {
  if (CERTIFIED_MEDIA_ARCHIVE_BYTES !== 684_210_625) {
    throw new Error("media archive byte authority regression");
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
