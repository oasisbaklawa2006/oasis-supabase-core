import { expandTokenSynonyms, expandTokenSynonymsList } from "./synonymMap.ts";

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  const row = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const next = Math.min(row[j] + 1, prev + 1, row[j - 1] + cost);
      row[j - 1] = prev;
      prev = next;
    }
    row[b.length] = prev;
  }
  return row[b.length];
}

function tokenMatchScore(q: string, c: string): number {
  if (!q || !c) return 0;
  if (q === c) return 1;
  const maxLen = Math.max(q.length, c.length);
  if (maxLen <= 3) return 0;
  const dist = levenshtein(q, c);
  if (dist === 1 && maxLen >= 5) return 0.88;
  if (dist <= 2 && maxLen >= 7) return 0.75;
  if (c.includes(q) || q.includes(c)) return 0.72;
  return 0;
}

/** Order-independent token overlap with synonym expansion on query side. */
export function tokenOverlapScore(queryTokens: string[], candidateTokens: string[]): number {
  if (queryTokens.length === 0 || candidateTokens.length === 0) return 0;

  const qExpanded = expandTokenSynonymsList(queryTokens);
  const cSet = new Set(candidateTokens);

  let matched = 0;
  const usedC = new Set<string>();
  for (const q of qExpanded) {
    if (cSet.has(q) && !usedC.has(q)) {
      matched++;
      usedC.add(q);
      continue;
    }
    let best = 0;
    let bestC = "";
    for (const c of candidateTokens) {
      if (usedC.has(c)) continue;
      const s = tokenMatchScore(q, c);
      if (s > best) {
        best = s;
        bestC = c;
      }
    }
    if (best >= 0.72) {
      matched += best;
      if (bestC) usedC.add(bestC);
    }
  }

  const denom = Math.max(queryTokens.length, candidateTokens.length);
  let score = matched / denom;

  const allCandInQ = candidateTokens.every((c) => {
    if (queryTokens.includes(c)) return true;
    return queryTokens.some((q) => expandTokenSynonyms(q).includes(c));
  });
  const allQInCand = queryTokens.every((q) => {
    if (cSet.has(q)) return true;
    return expandTokenSynonyms(q).some((s) => cSet.has(s));
  });
  if (allCandInQ && allQInCand) {
    score = Math.max(score, 0.94);
  }

  return Math.min(1, score);
}

export function exactSkuScore(query: string, sku: string): number {
  const q = query.trim().toUpperCase();
  const s = sku.trim().toUpperCase();
  if (!q || !s) return 0;
  if (q === s) return 1;
  if (s.includes(q) || q.includes(s)) return 0.92;
  return 0;
}

export function packCountBoost(
  queryPackCount: number | null,
  candidateText: string,
  candidateSku: string,
): number {
  if (!queryPackCount) return 0;
  const hay = `${candidateText} ${candidateSku}`.toLowerCase();
  const hasPack =
    hay.includes(`${queryPackCount} pc`) ||
    hay.includes(`${queryPackCount}pcs`) ||
    hay.includes(`${queryPackCount} pcs`) ||
    hay.includes("maapet") ||
    hay.includes("gift pack");
  const isBulkOnly =
    hay.includes("bulk") && !hay.includes("maapet") && !hay.includes("gift pack");
  if (hasPack) return 0.25;
  if (isBulkOnly) return -0.2;
  return 0;
}

export function frozenIntentBoost(queryTokens: string[], candidateText: string): number {
  const frozen = queryTokens.includes("frozen");
  const text = candidateText.toLowerCase();
  if (frozen && text.includes("frozen")) return 0.12;
  if (frozen && text.includes("roasted")) return -0.1;
  return 0;
}

export function cheeseIntentBoost(queryTokens: string[], candidateText: string): number {
  const cheese = queryTokens.includes("cheese");
  const text = candidateText.toLowerCase();
  if (cheese && text.includes("cheese")) return 0.1;
  if (cheese && !text.includes("cheese") && text.includes("roasted")) return -0.08;
  return 0;
}

/** Boost when alias text matches the raw customer utterance exactly (order preserved). */
export function exactUtteranceAliasBoost(rawUtterance: string, aliasText: string): number {
  const raw = rawUtterance.trim().toLowerCase().replace(/\s+/g, " ");
  const alias = aliasText.trim().toLowerCase().replace(/\s+/g, " ");
  if (!raw || !alias) return 0;
  if (raw === alias) return 0.08;
  const rawTokens = raw.split(" ");
  const aliasTokens = alias.split(" ");
  if (
    rawTokens.length === aliasTokens.length &&
    rawTokens.every((t, i) => t === aliasTokens[i])
  ) {
    return 0.08;
  }
  if (rawTokens.length === aliasTokens.length && [...rawTokens].sort().join() === [...aliasTokens].sort().join()) {
    return 0.05;
  }
  return 0;
}

/** Prefer acceptance bulk SKUs when customer uses bulk-oriented phrasing. */
export function bulkPhraseBoost(rawUtterance: string, productName: string, sku: string): number {
  const raw = rawUtterance.toLowerCase();
  const name = productName.toLowerCase();
  if (raw.includes("bulk") && name.includes("bulk")) return 0.06;
  if (sku.includes("-BULK-") && !raw.includes("gift") && !raw.match(/\d+\s*pc/)) return 0.03;
  return 0;
}
