/** Static additive synonym config — no DB migration. */
const TOKEN_SYNONYMS: Readonly<Record<string, readonly string[]>> = {
  pista: ["pistachio", "pista"],
  pistachio: ["pista", "pistachio"],
  kaju: ["cashew", "kaju"],
  cashew: ["kaju", "cashew"],
  baklava: ["baklawa", "baklava"],
  baklawa: ["baklawa", "baklava"],
  kunafa: ["kunafa", "kunefe", "knafeh", "knafa"],
  kunefe: ["kunafa", "kunefe"],
  knafeh: ["kunafa", "knafeh"],
  knafa: ["kunafa", "knafa"],
  midya: ["midya", "midea", "mediya"],
  midea: ["midya", "midea"],
  mediya: ["midya", "mediya"],
  assiyah: ["assiyah", "asiyah", "assiya"],
  asiyah: ["assiyah", "asiyah", "assiya"],
  assiya: ["assiyah", "assiya"],
  bulbul: ["bulbul", "oshel", "bulbul"],
  badam: ["almond", "badam"],
  almond: ["badam", "almond"],
  channa: ["channa", "chana"],
  chana: ["channa", "chana"],
  dates: ["dates", "date"],
  date: ["dates", "date"],
  mithai: ["sweet", "mithai", "sweets"],
  sweet: ["mithai", "sweet", "sweets"],
  cheese: ["cheese"],
  frozen: ["frozen"],
  stuffed: ["stuffed"],
  tart: ["tart"],
  barfi: ["barfi"],
  mor: ["mor"],
  kitta: ["kitta"],
  pyramid: ["pyramid"],
};

/** Multi-word phrase expansions applied before tokenization. */
const PHRASE_SYNONYMS: ReadonlyArray<{ pattern: RegExp; replacement: string }> = [
  { pattern: /\bkunafa\s+cheese\b/gi, replacement: "kunafa cheese frozen" },
  { pattern: /\bfrozen\s+cheese\b/gi, replacement: "frozen cheese kunafa" },
  { pattern: /\bstuffed\s+dates\b/gi, replacement: "stuffed dates pista" },
  { pattern: /\bdates\s+pista\b/gi, replacement: "dates pista stuffed" },
  { pattern: /\bchanna\s+badam\b/gi, replacement: "channa badam barfi" },
  { pattern: /\bchana\s+badam\b/gi, replacement: "channa badam barfi" },
  { pattern: /\b(kaju|cashew)\s+tart\b|\btart\s+(kaju|cashew)\b/gi, replacement: "cashew tart" },
  { pattern: /\bpista\s+bulbul\b/gi, replacement: "pista bulbul pistachio" },
  { pattern: /\bosh\s*el\s*bulbul\b/gi, replacement: "bulbul pista" },
  { pattern: /\boshel\s+bulbul\b/gi, replacement: "bulbul pista" },
];

export function applyPhraseSynonyms(text: string): string {
  let out = text;
  for (const { pattern, replacement } of PHRASE_SYNONYMS) {
    out = out.replace(pattern, replacement);
  }
  return out;
}

export function expandTokenSynonyms(token: string): string[] {
  const syns = TOKEN_SYNONYMS[token];
  if (!syns) return [token];
  return [...new Set([token, ...syns])];
}

export function expandTokenSynonymsList(tokens: string[]): string[] {
  const out = new Set<string>();
  for (const token of tokens) {
    for (const s of expandTokenSynonyms(token)) out.add(s);
  }
  return [...out];
}
