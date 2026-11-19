/**
 * Bounded XLSX -> plain TSV text extraction for Genie order evidence.
 *
 * Why: Gemini cannot read spreadsheets inline, and merely allow-listing the
 * MIME type would forward opaque bytes. This extractor is deliberately small
 * and fail-closed: it reads only the worksheet/shared-string parts it needs,
 * enforces archive, expansion, row, column and output limits, refuses macros,
 * external links, encryption, ZIP64 and any XML DTD/entity declaration, and
 * NEVER silently truncates (a truncated order would drop lines unnoticed).
 *
 * Legacy binary .xls (BIFF) is intentionally NOT supported.
 */
export const XLSX_MIME_TYPE =
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

export const SPREADSHEET_LIMITS = {
  maxArchiveBytes: 5 * 1024 * 1024,
  maxEntries: 256,
  maxPartInflatedBytes: 4 * 1024 * 1024,
  maxTotalInflatedBytes: 8 * 1024 * 1024,
  maxInflateRatio: 100,
  maxSheets: 3,
  maxRows: 500,
  maxCols: 30,
  maxSharedStrings: 20000,
  maxOutputChars: 60 * 1024,
} as const;

export class SpreadsheetExtractionError extends Error {}
const fail = (message: string): never => {
  throw new SpreadsheetExtractionError(message);
};

interface ZipEntry {
  name: string;
  method: number;
  compressedSize: number;
  size: number;
  localOffset: number;
}

const u16 = (b: Uint8Array, o: number) => b[o] | (b[o + 1] << 8);
const u32 = (b: Uint8Array, o: number) =>
  (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)) + b[o + 3] * 0x1000000;

function readCentralDirectory(zip: Uint8Array): Map<string, ZipEntry> {
  const L = SPREADSHEET_LIMITS;
  if (zip.length > L.maxArchiveBytes) fail("spreadsheet is too large");
  if (zip.length < 22 || u32(zip, 0) !== 0x04034b50) {
    fail("file is not a valid .xlsx workbook");
  }
  let eocd = -1;
  for (
    let i = zip.length - 22;
    i >= Math.max(0, zip.length - 22 - 65535);
    i--
  ) {
    if (u32(zip, i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) fail("file is not a valid .xlsx workbook");
  const count = u16(zip, eocd + 10);
  const cdSize = u32(zip, eocd + 12);
  const cdOffset = u32(zip, eocd + 16);
  if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
    fail("ZIP64 workbooks are not supported");
  }
  if (count > L.maxEntries) fail("workbook has too many parts");
  if (cdOffset + cdSize > eocd) fail("file is not a valid .xlsx workbook");

  const entries = new Map<string, ZipEntry>();
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    if (p + 46 > zip.length || u32(zip, p) !== 0x02014b50) {
      fail("file is not a valid .xlsx workbook");
    }
    const flags = u16(zip, p + 8);
    const nameLen = u16(zip, p + 28);
    const extraLen = u16(zip, p + 30);
    const commentLen = u16(zip, p + 32);
    if (flags & 1) fail("encrypted workbooks are not supported");
    const name = new TextDecoder().decode(
      zip.subarray(p + 46, p + 46 + nameLen),
    );
    if (entries.has(name)) fail("workbook has duplicate parts");
    entries.set(name, {
      name,
      method: u16(zip, p + 10),
      compressedSize: u32(zip, p + 20),
      size: u32(zip, p + 24),
      localOffset: u32(zip, p + 42),
    });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

async function inflatePart(
  zip: Uint8Array,
  entry: ZipEntry,
  budget: { remaining: number },
): Promise<Uint8Array> {
  const L = SPREADSHEET_LIMITS;
  const o = entry.localOffset;
  if (o + 30 > zip.length || u32(zip, o) !== 0x04034b50) {
    fail("file is not a valid .xlsx workbook");
  }
  const start = o + 30 + u16(zip, o + 26) + u16(zip, o + 28);
  const end = start + entry.compressedSize;
  if (end > zip.length) fail("file is not a valid .xlsx workbook");
  const raw = zip.subarray(start, end);
  const cap = Math.min(L.maxPartInflatedBytes, budget.remaining);
  if (entry.size > cap) fail("spreadsheet is too large when expanded");
  if (
    entry.compressedSize > 0 &&
    entry.size / entry.compressedSize > L.maxInflateRatio
  ) {
    fail("spreadsheet compression ratio is not allowed");
  }
  let out: Uint8Array;
  if (entry.method === 0) {
    out = raw.slice();
  } else if (entry.method === 8) {
    const reader = new Blob([raw as BlobPart]).stream()
      .pipeThrough(new DecompressionStream("deflate-raw")).getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > cap) {
        await reader.cancel();
        fail("spreadsheet is too large when expanded");
      }
      chunks.push(value);
    }
    out = new Uint8Array(total);
    let at = 0;
    for (const c of chunks) {
      out.set(c, at);
      at += c.length;
    }
  } else {
    return fail("unsupported workbook compression");
  }
  if (out.length !== entry.size) fail("file is not a valid .xlsx workbook");
  budget.remaining -= out.length;
  return out;
}

function decodeXmlText(value: string): string {
  return value.replace(
    /&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);/g,
    (_m, e: string) => {
      switch (e) {
        case "amp":
          return "&";
        case "lt":
          return "<";
        case "gt":
          return ">";
        case "quot":
          return '"';
        case "apos":
          return "'";
      }
      const cp = e[1] === "x"
        ? parseInt(e.slice(2), 16)
        : parseInt(e.slice(1), 10);
      return Number.isInteger(cp) && cp >= 32 && cp <= 0x10ffff &&
          !(cp >= 0xd800 && cp <= 0xdfff)
        ? String.fromCodePoint(cp)
        : "";
    },
  );
}

function xmlString(bytes: Uint8Array): string {
  const xml = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) {
    fail("workbook XML declarations are not allowed");
  }
  return xml;
}

/** Concatenate <t> runs; ignores phonetic (<rPh>) text. */
function textRuns(fragment: string): string {
  const cleaned = fragment.replace(/<rPh\b[\s\S]*?<\/rPh>/g, "");
  let out = "";
  for (const m of cleaned.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)) {
    out += decodeXmlText(m[1]);
  }
  return out;
}

function parseSharedStrings(xml: string): string[] {
  const strings: string[] = [];
  for (const m of xml.matchAll(/<si(?:\s[^>]*)?>([\s\S]*?)<\/si>|<si\s*\/>/g)) {
    if (strings.length >= SPREADSHEET_LIMITS.maxSharedStrings) {
      fail("spreadsheet has too many strings");
    }
    strings.push(textRuns(m[1] ?? ""));
  }
  return strings;
}

const colIndex = (ref: string): number => {
  let n = 0;
  for (const ch of ref.replace(/[0-9]/g, "")) {
    n = n * 26 + (ch.charCodeAt(0) - 64);
  }
  return n - 1;
};

function sheetToRows(xml: string, shared: string[]): string[][] {
  const L = SPREADSHEET_LIMITS;
  const rows: string[][] = [];
  for (const rm of xml.matchAll(/<row\b[^>]*?(?:\/>|>([\s\S]*?)<\/row>)/g)) {
    const cells: string[] = [];
    for (
      const cm of (rm[1] ?? "").matchAll(
        /<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g,
      )
    ) {
      const attrs = cm[1];
      const body = cm[2] ?? "";
      const ref = /\br="([A-Z]{1,3})[0-9]+"/.exec(attrs)?.[1];
      const type = /\bt="([a-zA-Z]+)"/.exec(attrs)?.[1] ?? "n";
      const idx = ref ? colIndex(ref) : cells.length;
      if (idx < 0 || idx >= L.maxCols) {
        if (idx >= L.maxCols && body.trim()) {
          fail("spreadsheet has too many columns");
        }
        continue;
      }
      let value = "";
      if (type === "inlineStr") {
        value = textRuns(body);
      } else {
        const v = /<v>([\s\S]*?)<\/v>/.exec(body)?.[1];
        if (v !== undefined) {
          if (type === "s") {
            const si = Number(v);
            if (!Number.isInteger(si) || si < 0 || si >= shared.length) {
              fail("workbook is internally inconsistent");
            }
            value = shared[si];
          } else if (type === "e") {
            value = "";
          } else {
            value = decodeXmlText(v);
          }
        }
      }
      while (cells.length <= idx) cells.push("");
      cells[idx] = value.replace(/[\t\r\n]+/g, " ").trim();
    }
    if (cells.some((c) => c !== "")) {
      if (rows.length >= L.maxRows) fail("spreadsheet has too many rows");
      rows.push(cells);
    }
  }
  return rows;
}

/** Returns canonical tab-separated text, one order row per line. */
export async function extractXlsxOrderText(bytes: Uint8Array): Promise<string> {
  const L = SPREADSHEET_LIMITS;
  const entries = readCentralDirectory(bytes);
  for (const name of entries.keys()) {
    if (/vbaProject|externalLinks\/|embeddings\/|\.\.|^\/|\\/i.test(name)) {
      fail(
        "workbooks with macros, embedded objects or external links are not supported",
      );
    }
  }
  if (!entries.has("[Content_Types].xml") || !entries.has("xl/workbook.xml")) {
    fail("file is not a valid .xlsx workbook");
  }
  const budget = { remaining: L.maxTotalInflatedBytes };
  const sharedEntry = entries.get("xl/sharedStrings.xml");
  const shared = sharedEntry
    ? parseSharedStrings(
      xmlString(await inflatePart(bytes, sharedEntry, budget)),
    )
    : [];
  const sheetNames = [...entries.keys()]
    .filter((n) => /^xl\/worksheets\/sheet[0-9]+\.xml$/.test(n))
    .sort((a, b) =>
      Number(a.match(/[0-9]+/)![0]) - Number(b.match(/[0-9]+/)![0])
    );
  if (sheetNames.length === 0) fail("workbook has no worksheets");
  if (sheetNames.length > L.maxSheets) {
    fail("workbook has too many sheets; send one order sheet");
  }

  const lines: string[] = [];
  for (const name of sheetNames) {
    const xml = xmlString(await inflatePart(bytes, entries.get(name)!, budget));
    for (const row of sheetToRows(xml, shared)) lines.push(row.join("\t"));
  }
  const text = lines.join("\n");
  if (!text.trim()) fail("spreadsheet contains no readable order text");
  if (text.length > L.maxOutputChars) {
    fail("spreadsheet text is too long; split the order");
  }
  return text;
}
