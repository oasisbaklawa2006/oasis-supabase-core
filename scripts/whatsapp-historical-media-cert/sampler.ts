import type { PairedMediaReference } from "./types.ts";

function hashScore(seed: string, caseId: string): number {
  let h = 0;
  const input = `${seed}:${caseId}`;
  for (let i = 0; i < input.length; i++) {
    h = (h * 31 + input.charCodeAt(i)) >>> 0;
  }
  return h;
}

/** Deterministic stratified sampling with per-stratum minimum coverage. */
export function selectExecutionSample(
  population: PairedMediaReference[],
  maxCases: number,
  seed = "wa-hist-media-v1",
): { selected: PairedMediaReference[]; rule: string } {
  const eligible = population.filter((p) => p.eligible);
  if (maxCases <= 0 || eligible.length <= maxCases) {
    return {
      selected: eligible,
      rule: maxCases <= 0
        ? "FULL_ELIGIBLE_EXECUTION"
        : `FULL_ELIGIBLE_UNDER_CAP_${maxCases}`,
    };
  }

  const byStratum = new Map<string, PairedMediaReference[]>();
  for (const item of eligible) {
    const bucket = byStratum.get(item.stratum) ?? [];
    bucket.push(item);
    byStratum.set(item.stratum, bucket);
  }

  const strata = [...byStratum.keys()].sort();
  const minPerStratum = Math.max(1, Math.floor(maxCases / Math.max(strata.length, 1)));
  const selected: PairedMediaReference[] = [];
  const selectedIds = new Set<string>();

  for (const stratum of strata) {
    const bucket = [...(byStratum.get(stratum) ?? [])].sort((a, b) => {
      const delta = hashScore(seed, a.case_id) - hashScore(seed, b.case_id);
      return delta !== 0 ? delta : a.case_id.localeCompare(b.case_id);
    });
    if (!bucket.length) continue;
    const picks = bucket.slice(0, Math.min(minPerStratum, bucket.length));
    for (const pick of picks) {
      if (selected.length >= maxCases) break;
      if (selectedIds.has(pick.case_id)) continue;
      selected.push(pick);
      selectedIds.add(pick.case_id);
    }
    if (selected.length >= maxCases) break;
  }

  const remaining = maxCases - selected.length;
  const pool = eligible
    .filter((item) => !selectedIds.has(item.case_id))
    .sort((a, b) => hashScore(seed, a.case_id) - hashScore(seed, b.case_id));

  for (const item of pool.slice(0, Math.max(0, remaining))) {
    selected.push(item);
    selectedIds.add(item.case_id);
  }

  return {
    selected: selected.sort((a, b) => a.message_index - b.message_index),
    rule:
      `STRATIFIED_LOCKED_SAMPLE:seed=${seed}:max=${maxCases}:strata=${strata.length}:min_per_stratum=${minPerStratum}`,
  };
}

export const REQUIRED_STRATA_HINTS = [
  "IMAGE:IMAGE_ONLY",
  "IMAGE:SCREENSHOT",
  "IMAGE:FORWARDED_SCREENSHOT",
  "IMAGE:HANDWRITTEN_ORDER",
  "IMAGE:PRODUCT_LABEL_VISIBLE",
  "IMAGE:CATALOGUE_SCREENSHOT",
  "IMAGE:PAYMENT_PROOF",
  "IMAGE:COMPLAINT_DAMAGE",
  "IMAGE:MEDIA_WITH_CORRECTION",
  "PDF:ORDER",
  "AUDIO:ORDER",
  "VIDEO:ORDER",
];
