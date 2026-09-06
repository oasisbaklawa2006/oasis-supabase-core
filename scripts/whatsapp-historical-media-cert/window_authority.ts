import { parseWhatsAppExport } from "../whatsapp-stage2-historical/parse_export.ts";
import { buildCertificationWindows } from "../whatsapp-stage2-historical/segment.ts";

/** Provisional v2-era window count superseded by September v3 authority. */
export const SUPERSEDED_V2_CERTIFICATION_WINDOWS = 8754;

/** Canonical September protected-corpus window count (PR #186 / #188 / Stage-2 v3). */
export const CANONICAL_V3_CERTIFICATION_WINDOWS = 8804;

export type WindowAuthorityReconciliation = {
  canonical_v3_windows: number;
  superseded_v2_windows: number;
  observed_v3_windows: number;
  authority: "CANONICAL_V3_8804";
  reconciliation_note: string;
};

export function reconcileWindowAuthority(
  observedWindows: number,
): WindowAuthorityReconciliation {
  return {
    canonical_v3_windows: CANONICAL_V3_CERTIFICATION_WINDOWS,
    superseded_v2_windows: SUPERSEDED_V2_CERTIFICATION_WINDOWS,
    observed_v3_windows: observedWindows,
    authority: "CANONICAL_V3_8804",
    reconciliation_note:
      observedWindows === CANONICAL_V3_CERTIFICATION_WINDOWS
        ? "September v3 window segmentation authority (8,804) verified on mounted corpus. Historical provisional v2 figure (8,754) is superseded and must not be used for certification gates."
        : `Window count mismatch: observed ${observedWindows}, canonical ${CANONICAL_V3_CERTIFICATION_WINDOWS}. Fail closed.`,
  };
}

export function verifyWindowAuthorityFromExport(
  mediaExportText: string,
): WindowAuthorityReconciliation {
  const messages = parseWhatsAppExport(mediaExportText);
  const observed = buildCertificationWindows(messages).length;
  return reconcileWindowAuthority(observed);
}
