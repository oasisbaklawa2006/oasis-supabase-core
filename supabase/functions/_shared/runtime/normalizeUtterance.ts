import { applyPhraseSynonyms } from "./synonymMap.ts";

const FILLERS = new Set([
  "pls",
  "please",
  "want",
  "need",
  "order",
  "give",
  "send",
  "one",
  "some",
  "the",
  "a",
  "an",
  "of",
  "for",
  "me",
  "mujhe",
  "chahiye",
  "dedo",
  "bhejo",
  "kilo",
  "kg",
  "gram",
  "gms",
]);

const UNIT_NOISE = new Set(["pc", "pcs", "piece", "pieces", "pkt", "pack"]);

export interface NormalizedUtterance {
  raw: string;
  normalized_text: string;
  tokens: string[];
  pack_count: number | null;
  /** Retains pack qty for alias matching e.g. "6 pc midya". */
  alias_match_text: string;
}

const SKU_PATTERN = /^OAS-[A-Z0-9-]+$/i;

export function extractPackCount(text: string): number | null {
  const packMatch = text.match(/\b(\d{1,3})\s*(?:pc|pcs|piece|pieces)\b/i);
  return packMatch ? Number(packMatch[1]) : null;
}

export function normalizeUtterance(raw: string): NormalizedUtterance {
  const trimmed = raw.trim();
  if (SKU_PATTERN.test(trimmed)) {
    return {
      raw: trimmed,
      normalized_text: trimmed.toUpperCase(),
      tokens: [trimmed.toUpperCase()],
      pack_count: null,
      alias_match_text: trimmed.toUpperCase(),
    };
  }

  let text = trimmed.toLowerCase();
  text = applyPhraseSynonyms(text);

  let pack_count: number | null = null;
  const packMatch = text.match(/\b(\d{1,3})\s*(?:pc|pcs|piece|pieces)\b/);
  const alias_match_text = packMatch ? text.trim() : text.trim();
  if (packMatch) {
    pack_count = Number(packMatch[1]);
    text = text.replace(packMatch[0], " ").trim();
  }

  const tokens = text
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter((t) => t.length > 0 && !FILLERS.has(t) && !UNIT_NOISE.has(t));

  return {
    raw: trimmed,
    normalized_text: tokens.join(" "),
    tokens,
    pack_count,
    alias_match_text: alias_match_text.replace(/[^a-z0-9\s-]/g, " ").replace(/\s+/g, " ").trim(),
  };
}
