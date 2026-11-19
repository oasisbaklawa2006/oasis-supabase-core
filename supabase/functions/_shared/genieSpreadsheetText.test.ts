import {
  extractXlsxOrderText,
  SPREADSHEET_LIMITS,
  SpreadsheetExtractionError,
} from "./genieSpreadsheetText.ts";

const enc = new TextEncoder();
function crc32(b: Uint8Array): number {
  let c, crc = 0xffffffff;
  for (let i = 0; i < b.length; i++) {
    c = (crc ^ b[i]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
async function deflate(b: Uint8Array): Promise<Uint8Array> {
  const s = new Blob([b as BlobPart]).stream().pipeThrough(
    new CompressionStream("deflate-raw"),
  );
  return new Uint8Array(await new Response(s).arrayBuffer());
}
const w16 = (n: number) => [n & 255, (n >> 8) & 255];
const w32 = (
  n: number,
) => [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >>> 24) & 255];

async function zip(
  files: Record<string, string | Uint8Array>,
  opts: { stored?: boolean; flags?: number } = {},
) {
  const parts: number[][] = [];
  const central: number[][] = [];
  let offset = 0;
  for (const [name, content] of Object.entries(files)) {
    const data = typeof content === "string" ? enc.encode(content) : content;
    const comp = opts.stored ? data : await deflate(data);
    const method = opts.stored ? 0 : 8;
    const nm = [...enc.encode(name)];
    const local = [
      ...w32(0x04034b50),
      ...w16(20),
      ...w16(opts.flags ?? 0),
      ...w16(method),
      ...w16(0),
      ...w16(0),
      ...w32(crc32(data)),
      ...w32(comp.length),
      ...w32(data.length),
      ...w16(nm.length),
      ...w16(0),
      ...nm,
      ...comp,
    ];
    central.push([
      ...w32(0x02014b50),
      ...w16(20),
      ...w16(20),
      ...w16(opts.flags ?? 0),
      ...w16(method),
      ...w16(0),
      ...w16(0),
      ...w32(crc32(data)),
      ...w32(comp.length),
      ...w32(data.length),
      ...w16(nm.length),
      ...w16(0),
      ...w16(0),
      ...w16(0),
      ...w16(0),
      ...w32(0),
      ...w32(offset),
      ...nm,
    ]);
    parts.push(local);
    offset += local.length;
  }
  const cd = central.flat();
  const end = [
    ...w32(0x06054b50),
    ...w16(0),
    ...w16(0),
    ...w16(central.length),
    ...w16(central.length),
    ...w32(cd.length),
    ...w32(offset),
    ...w16(0),
  ];
  return new Uint8Array([...parts.flat(), ...cd, ...end]);
}

const base = {
  "[Content_Types].xml": "<Types/>",
  "xl/workbook.xml": "<workbook/>",
};
const sheet = (rows: string) =>
  `<worksheet><sheetData>${rows}</sheetData></worksheet>`;
const sst = (...s: string[]) =>
  `<sst>${s.map((x) => `<si><t>${x}</t></si>`).join("")}</sst>`;

async function rejects(bytes: Uint8Array, match: RegExp) {
  try {
    await extractXlsxOrderText(bytes);
  } catch (e) {
    if (!(e instanceof SpreadsheetExtractionError)) throw e;
    if (!match.test(e.message)) throw new Error(`wrong error: ${e.message}`);
    return;
  }
  throw new Error("expected rejection");
}

Deno.test("extracts shared-string, inline and numeric cells in order incl. Hindi and sparse columns", async () => {
  const x = await zip({
    ...base,
    "xl/sharedStrings.xml": sst("Product", "Qty", "काजू कतली &amp; Co"),
    "xl/worksheets/sheet1.xml": sheet(
      `<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>` +
        `<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>5</v></c></row>` +
        `<row r="3"><c r="A3" t="inlineStr"><is><t>Pista</t></is></c><c r="B3"><v>2.5</v></c></row>`,
    ),
  });
  const text = await extractXlsxOrderText(x);
  if (text !== "Product\tQty\nकाजू कतली & Co\t\t5\nPista\t2.5") {
    throw new Error(JSON.stringify(text));
  }
});

Deno.test("stored (uncompressed) parts work", async () => {
  const x = await zip({
    ...base,
    "xl/worksheets/sheet1.xml": sheet(`<row><c r="A1"><v>7</v></c></row>`),
  }, { stored: true });
  if ((await extractXlsxOrderText(x)) !== "7") throw new Error("bad");
});

Deno.test("rejects non-zip, macros, external links, encrypted and DTD/entity content", async () => {
  await rejects(enc.encode("not a zip at all, plain text"), /not a valid/);
  await rejects(
    await zip({
      ...base,
      "xl/vbaProject.bin": "x",
      "xl/worksheets/sheet1.xml": sheet(""),
    }),
    /macros/,
  );
  await rejects(
    await zip({
      ...base,
      "xl/externalLinks/externalLink1.xml": "x",
      "xl/worksheets/sheet1.xml": sheet(""),
    }),
    /external links/,
  );
  await rejects(
    await zip({ ...base, "xl/worksheets/sheet1.xml": sheet("") }, { flags: 1 }),
    /encrypted/,
  );
  await rejects(
    await zip({
      ...base,
      "xl/worksheets/sheet1.xml": `<!DOCTYPE x [<!ENTITY a "b">]>` +
        sheet(`<row><c r="A1"><v>1</v></c></row>`),
    }),
    /declarations/,
  );
});

Deno.test("rejects path traversal names, missing workbook, empty sheets", async () => {
  await rejects(
    await zip({
      ...base,
      "../evil.xml": "x",
      "xl/worksheets/sheet1.xml": sheet(""),
    }),
    /macros|not supported/,
  );
  await rejects(
    await zip({
      "xl/worksheets/sheet1.xml": sheet(`<row><c r="A1"><v>1</v></c></row>`),
    }),
    /not a valid/,
  );
  await rejects(
    await zip({ ...base, "xl/worksheets/sheet1.xml": sheet("") }),
    /no readable/,
  );
});

Deno.test("zip bomb, row, column and sheet limits fail closed (never truncate)", async () => {
  const bomb = "<worksheet>" +
    "a".repeat(SPREADSHEET_LIMITS.maxPartInflatedBytes + 10) + "</worksheet>";
  await rejects(
    await zip({ ...base, "xl/worksheets/sheet1.xml": bomb }),
    /too large|ratio/,
  );
  const manyRows = Array.from(
    { length: SPREADSHEET_LIMITS.maxRows + 1 },
    (_, i) => `<row><c r="A${i + 1}"><v>${i}</v></c></row>`,
  ).join("");
  await rejects(
    await zip({ ...base, "xl/worksheets/sheet1.xml": sheet(manyRows) }),
    /too many rows/,
  );
  await rejects(
    await zip({
      ...base,
      "xl/worksheets/sheet1.xml": sheet(`<row><c r="AZ1"><v>1</v></c></row>`),
    }),
    /too many columns/,
  );
  const sheets = Object.fromEntries(
    [1, 2, 3, 4].map((
      n,
    ) => [
      `xl/worksheets/sheet${n}.xml`,
      sheet(`<row><c r="A1"><v>1</v></c></row>`),
    ]),
  );
  await rejects(await zip({ ...base, ...sheets }), /too many sheets/);
});

Deno.test("bad shared-string index is an integrity failure, not a guess", async () => {
  await rejects(
    await zip({
      ...base,
      "xl/sharedStrings.xml": sst("a"),
      "xl/worksheets/sheet1.xml": sheet(
        `<row><c r="A1" t="s"><v>9</v></c></row>`,
      ),
    }),
    /inconsistent/,
  );
});
