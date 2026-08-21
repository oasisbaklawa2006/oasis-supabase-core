import { extractPackCount } from "./normalizeUtterance.ts";

/**
 * Advisory lexical extraction only. A missing number is an unresolved fact;
 * it must never be converted into a one-unit commercial line.
 */
// skipcq: JS-0067
export function extractOrderQuantity(text: string): number | null {
  const pack = extractPackCount(text);
  if (pack != null && pack > 0) return pack;

  const trimmed = text.trim();
  const leading = trimmed.match(/^\s*(\d{1,4})\b/);
  if (leading) {
    const value = Number(leading[1]);
    if (value > 0) return value;
  }

  const unitQty = trimmed.match(
    /\b(\d{1,4})\s*(?:kg|kilo|g|gm|gms|gram|box|boxes|pkt|pack)\b/i,
  );
  if (unitQty) {
    const value = Number(unitQty[1]);
    if (value > 0) return value;
  }

  return null;
}
