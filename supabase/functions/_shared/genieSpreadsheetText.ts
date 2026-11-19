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
      // Tab/LF/CR are legal XML references; they are normalized to a single
      // space at cell level so encoded line breaks keep word boundaries.
      const ok = Number.isInteger(cp) &&
        (cp === 9 || cp === 10 || cp === 13 ||
          (cp >= 32 && cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff)));
      return ok ? String.fromCodePoint(cp) : "";
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

const localName = (name: string): string => {
  const at = name.indexOf(":");
  return at < 0 ? name : name.slice(at + 1);
};

interface XmlHandlers {
  open(local: string, attrs: Record<string, string>): void;
  close(local: string): void;
  text(text: string): void;
}

/**
 * Single-pass, linear XML tokenizer (no regex backtracking, so a hostile
 * sheet cannot cause quadratic work). Element and attribute names are matched
 * by LOCAL name, so namespace prefixes (x:row) are supported; both quote
 * styles are accepted. Anything malformed fails the whole workbook.
 */
function scanXml(xml: string, h: XmlHandlers): void {
  const n = xml.length;
  let i = 0;
  const malformed = () => fail("workbook XML is malformed");
  while (i < n) {
    const lt = xml.indexOf("<", i);
    if (lt < 0) {
      h.text(decodeXmlText(xml.slice(i)));
      return;
    }
    if (lt > i) h.text(decodeXmlText(xml.slice(i, lt)));
    if (xml.startsWith("<!--", lt)) {
      const e = xml.indexOf("-->", lt + 4);
      if (e < 0) malformed();
      i = e + 3;
      continue;
    }
    if (xml.startsWith("<![CDATA[", lt)) {
      const e = xml.indexOf("]]>", lt + 9);
      if (e < 0) malformed();
      h.text(xml.slice(lt + 9, e));
      i = e + 3;
      continue;
    }
    if (xml.startsWith("<?", lt)) {
      const e = xml.indexOf("?>", lt + 2);
      if (e < 0) malformed();
      i = e + 2;
      continue;
    }
    if (xml.charCodeAt(lt + 1) === 47) { // "</"
      const e = xml.indexOf(">", lt);
      if (e < 0) malformed();
      h.close(localName(xml.slice(lt + 2, e).trim()));
      i = e + 1;
      continue;
    }
    let j = lt + 1;
    while (j < n && !/[\s/>]/.test(xml[j])) j++;
    const name = localName(xml.slice(lt + 1, j));
    if (!name) malformed();
    const attrs: Record<string, string> = {};
    let selfClosing = false;
    for (;;) {
      while (j < n && /\s/.test(xml[j])) j++;
      if (j >= n) malformed();
      if (xml[j] === ">") break;
      if (xml[j] === "/" && xml[j + 1] === ">") {
        selfClosing = true;
        j += 1;
        break;
      }
      let k = j;
      while (k < n && !/[\s=/>]/.test(xml[k])) k++;
      const attrName = localName(xml.slice(j, k));
      if (!attrName) malformed();
      j = k;
      while (j < n && /\s/.test(xml[j])) j++;
      if (xml[j] !== "=") malformed();
      j++;
      while (j < n && /\s/.test(xml[j])) j++;
      const quote = xml[j];
      if (quote !== '"' && quote !== "'") malformed();
      const end = xml.indexOf(quote, j + 1);
      if (end < 0) malformed();
      if (!(attrName in attrs)) {
        attrs[attrName] = decodeXmlText(xml.slice(j + 1, end));
      }
      j = end + 1;
    }
    i = j + 1;
    h.open(name, attrs);
    if (selfClosing) h.close(name);
  }
}

function parseSharedStrings(xml: string): string[] {
  const strings: string[] = [];
  let inSi = false;
  let inT = false;
  let phonetic = 0;
  let current = "";
  scanXml(xml, {
    open(local) {
      if (local === "si") {
        if (inSi) fail("workbook XML is malformed");
        inSi = true;
        current = "";
      } else if (local === "rPh") phonetic++;
      else if (local === "t" && inSi && phonetic === 0) inT = true;
    },
    close(local) {
      if (local === "t") inT = false;
      else if (local === "rPh") phonetic = Math.max(0, phonetic - 1);
      else if (local === "si") {
        if (strings.length >= SPREADSHEET_LIMITS.maxSharedStrings) {
          fail("spreadsheet has too many strings");
        }
        strings.push(current);
        inSi = false;
      }
    },
    text(t) {
      if (inT) current += t;
    },
  });
  if (inSi) fail("workbook XML is malformed");
  return strings;
}

const CELL_TYPES = new Set(["n", "s", "str", "inlineStr", "b", "e", "d"]);

function colIndex(ref: string): number {
  const m = /^([A-Z]{1,3})[0-9]+$/.exec(ref);
  if (!m) return fail("workbook has an invalid cell reference");
  let n = 0;
  for (const ch of m[1]) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

function sheetToRows(xml: string, shared: string[]): string[][] {
  const L = SPREADSHEET_LIMITS;
  const rows: string[][] = [];
  let row: string[] | null = null;
  let cell: { idx: number; type: string; value: string } | null = null;
  let collecting = false;
  let inInline = false;
  let phonetic = 0;
  const malformed = () => fail("workbook XML is malformed");

  scanXml(xml, {
    open(local, attrs) {
      switch (local) {
        case "row":
          if (row) malformed();
          row = [];
          break;
        case "c": {
          if (!row || cell) malformed();
          const type = attrs.t ?? "n";
          if (!CELL_TYPES.has(type)) {
            fail("workbook has an unsupported cell type");
          }
          const idx = attrs.r === undefined ? row!.length : colIndex(attrs.r);
          cell = { idx, type, value: "" };
          break;
        }
        case "v":
          if (cell && cell.type !== "inlineStr") collecting = true;
          break;
        case "is":
          if (cell) inInline = true;
          break;
        case "rPh":
          phonetic++;
          break;
        case "t":
          if (cell && inInline && phonetic === 0) collecting = true;
          break;
      }
    },
    close(local) {
      switch (local) {
        case "v":
        case "t":
          collecting = false;
          break;
        case "is":
          inInline = false;
          break;
        case "rPh":
          phonetic = Math.max(0, phonetic - 1);
          break;
        case "c": {
          if (!cell || !row) malformed();
          const c = cell!;
          let value = c.value;
          if (c.type === "s") {
            const si = Number(value.trim());
            if (!Number.isInteger(si) || si < 0 || si >= shared.length) {
              fail("workbook is internally inconsistent");
            }
            value = shared[si];
          } else if (c.type === "e") {
            value = "";
          }
          value = value.replace(/[\t\r\n]+/g, " ").trim();
          if (c.idx >= L.maxCols) {
            if (value !== "") fail("spreadsheet has too many columns");
          } else {
            const r = row!;
            while (r.length <= c.idx) r.push("");
            r[c.idx] = value;
          }
          cell = null;
          collecting = false;
          break;
        }
        case "row":
          if (!row || cell) malformed();
          if (row!.some((v) => v !== "")) {
            if (rows.length >= L.maxRows) fail("spreadsheet has too many rows");
            rows.push(row!);
          }
          row = null;
          break;
      }
    },
    text(t) {
      if (collecting && cell) cell.value += t;
    },
  });
  if (row || cell) malformed();
  return rows;
}

function resolvePart(target: string): string {
  const raw = target.startsWith("/") ? target.slice(1) : "xl/" + target;
  const out: string[] = [];
  for (const seg of raw.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (out.length === 0) fail("workbook has an invalid part reference");
      out.pop();
    } else out.push(seg);
  }
  return out.join("/");
}

/** Resolve worksheets in workbook order through workbook.xml + its relationships. */
function resolveWorksheetParts(
  workbookXml: string,
  relsXml: string,
  entries: Map<string, ZipEntry>,
): string[] {
  const rels = new Map<string, string>();
  scanXml(relsXml, {
    open(local, a) {
      if (local !== "Relationship") return;
      if (a.TargetMode?.toLowerCase() === "external") {
        fail("workbooks with external links are not supported");
      }
      if (a.Id && a.Target && a.Type?.endsWith("/worksheet")) {
        rels.set(a.Id, a.Target);
      }
    },
    close() {},
    text() {},
  });
  const parts: string[] = [];
  scanXml(workbookXml, {
    open(local, a) {
      if (local !== "sheet") return;
      const state = (a.state ?? "visible").toLowerCase();
      if (state === "hidden" || state === "veryhidden") return; // not buyer-visible
      const target = a.id === undefined ? undefined : rels.get(a.id);
      if (!target) fail("workbook sheet relationship is missing");
      const part = resolvePart(target!);
      if (
        !/^xl\/worksheets\/[A-Za-z0-9_.-]+\.xml$/.test(part) ||
        !entries.has(part)
      ) {
        fail("workbook sheet part is invalid");
      }
      if (parts.includes(part)) fail("workbook has duplicate sheets");
      parts.push(part);
    },
    close() {},
    text() {},
  });
  return parts;
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
  const workbook = entries.get("xl/workbook.xml");
  const rels = entries.get("xl/_rels/workbook.xml.rels");
  if (!entries.has("[Content_Types].xml") || !workbook || !rels) {
    fail("file is not a valid .xlsx workbook");
  }
  const budget = { remaining: L.maxTotalInflatedBytes };
  const sharedEntry = entries.get("xl/sharedStrings.xml");
  const shared = sharedEntry
    ? parseSharedStrings(
      xmlString(await inflatePart(bytes, sharedEntry, budget)),
    )
    : [];
  const sheetParts = resolveWorksheetParts(
    xmlString(await inflatePart(bytes, workbook!, budget)),
    xmlString(await inflatePart(bytes, rels!, budget)),
    entries,
  );
  if (sheetParts.length === 0) fail("workbook has no worksheets");
  if (sheetParts.length > L.maxSheets) {
    fail("workbook has too many sheets; send one order sheet");
  }

  const lines: string[] = [];
  for (const part of sheetParts) {
    const xml = xmlString(await inflatePart(bytes, entries.get(part)!, budget));
    for (const row of sheetToRows(xml, shared)) lines.push(row.join("\t"));
  }
  const text = lines.join("\n");
  if (!text.trim()) fail("spreadsheet contains no readable order text");
  if (text.length > L.maxOutputChars) {
    fail("spreadsheet text is too long; split the order");
  }
  return text;
}
