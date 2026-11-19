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

const XLSX_REL =
  "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet";
const MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const RELNS =
  "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const PKG = "http://schemas.openxmlformats.org/package/2006/relationships";
const sheet = (rows: string) =>
  `<worksheet xmlns="${MAIN}"><sheetData>${rows}</sheetData></worksheet>`;
const sst = (...s: string[]) =>
  `<sst xmlns="${MAIN}">${s.map((x) => `<si><t>${x}</t></si>`).join("")}</sst>`;

/** Build a workbook: sheets = [{part, xml, state?}] wired through workbook.xml + rels. */
function book(
  sheets: { part: string; xml: string; state?: string }[],
  extra: Record<string, string> = {},
  relTarget?: (part: string) => string,
) {
  const wb = `<workbook xmlns="${MAIN}" xmlns:r="${RELNS}"><sheets>${
    sheets.map((x, i) =>
      `<sheet name="S${i}" sheetId="${i + 1}"${
        x.state ? ` state="${x.state}"` : ""
      } r:id="rId${i + 1}"/>`
    ).join("")
  }</sheets></workbook>`;
  const rels = `<Relationships xmlns="${PKG}">${
    sheets.map((x, i) =>
      `<Relationship Id="rId${i + 1}" Type="${XLSX_REL}" Target="${
        relTarget ? relTarget(x.part) : x.part.replace(/^xl\//, "")
      }"/>`
    ).join("")
  }</Relationships>`;
  return {
    "[Content_Types].xml": "<Types/>",
    "xl/workbook.xml": wb,
    "xl/_rels/workbook.xml.rels": rels,
    ...Object.fromEntries(sheets.map((x) => [x.part, x.xml])),
    ...extra,
  };
}
const one = (xml: string, extra: Record<string, string> = {}) =>
  book([{ part: "xl/worksheets/sheet1.xml", xml }], extra);

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
const eq = (a: unknown, b: unknown) => {
  if (a !== b) {
    throw new Error(`expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
};

Deno.test("extracts shared-string, inline and numeric cells in order incl. Hindi and sparse columns", async () => {
  const x = await zip(one(
    sheet(
      `<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>` +
        `<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>5</v></c></row>` +
        `<row r="3"><c r="A3" t="inlineStr"><is><t>Pista</t></is></c><c r="B3"><v>2.5</v></c></row>`,
    ),
    { "xl/sharedStrings.xml": sst("Product", "Qty", "काजू कतली &amp; Co") },
  ));
  eq(
    await extractXlsxOrderText(x),
    "Product\tQty\nकाजू कतली & Co\t\t5\nPista\t2.5",
  );
});

Deno.test("stored (uncompressed) parts work", async () => {
  const x = await zip(one(sheet(`<row><c r="A1"><v>7</v></c></row>`)), {
    stored: true,
  });
  eq(await extractXlsxOrderText(x), "7");
});

Deno.test("namespace-prefixed worksheets and single-quoted attributes are read, not skipped", async () => {
  const xml = `<x:worksheet xmlns:x="${MAIN}"><x:sheetData>` +
    `<x:row r='1'><x:c r='A1' t='s'><x:v>0</x:v></x:c><x:c r='C1'><x:v>9</x:v></x:c></x:row>` +
    `</x:sheetData></x:worksheet>`;
  const x = await zip(one(xml, { "xl/sharedStrings.xml": sst("Product") }));
  eq(await extractXlsxOrderText(x), "Product\t\t9");
  // single-quoted out-of-range column must still be refused
  await rejects(
    await zip(one(sheet(`<row><c r='AZ1'><v>1</v></c></row>`))),
    /too many columns/,
  );
});

Deno.test("encoded whitespace keeps word boundaries; CDATA is literal", async () => {
  const x = await zip(one(sheet(
    `<row><c r="A1" t="inlineStr"><is><t>Pista&#10;500g</t></is></c></row>` +
      `<row><c r="A2" t="inlineStr"><is><t><![CDATA[A &amp; B]]></t></is></c></row>`,
  )));
  eq(await extractXlsxOrderText(x), "Pista 500g\nA &amp; B");
});

Deno.test("worksheets are resolved through relationships, not file names", async () => {
  const x = await zip(book([
    {
      part: "xl/worksheets/orders.xml",
      xml: sheet(`<row><c r="A1"><v>1</v></c></row>`),
    },
    {
      part: "xl/worksheets/sheet2.xml",
      xml: sheet(`<row><c r="A1"><v>2</v></c></row>`),
    },
  ]));
  eq(await extractXlsxOrderText(x), "1\n2");
  const abs = await zip(
    book(
      [{
        part: "xl/worksheets/a.xml",
        xml: sheet(`<row><c r="A1"><v>4</v></c></row>`),
      }],
      {},
      (p) => "/" + p,
    ),
  );
  eq(await extractXlsxOrderText(abs), "4");
});

Deno.test("valid OPC part names with parentheses, spaces and percent-encoding are accepted", async () => {
  const s = sheet(`<row><c r="A1"><v>5</v></c></row>`);
  eq(
    await extractXlsxOrderText(
      await zip(book([{ part: "xl/worksheets/orders(1).xml", xml: s }])),
    ),
    "5",
  );
  eq(
    await extractXlsxOrderText(
      await zip(book(
        [{ part: "xl/worksheets/my orders (2).xml", xml: s }],
        {},
        (p) => encodeURI(p.replace(/^xl\//, "")),
      )),
    ),
    "5",
  );
});

Deno.test("hidden sheets fail the workbook instead of being silently skipped", async () => {
  const s = sheet(`<row><c r="A1"><v>1</v></c></row>`);
  for (const state of ["hidden", "veryHidden"]) {
    await rejects(
      await zip(book([
        { part: "xl/worksheets/a.xml", xml: s },
        { part: "xl/worksheets/b.xml", xml: s, state },
      ])),
      /hidden sheets/,
    );
  }
});

Deno.test("broken, escaping or external sheet relationships fail the workbook", async () => {
  const s = sheet(`<row><c r="A1"><v>1</v></c></row>`);
  await rejects(
    await zip(
      book(
        [{ part: "xl/worksheets/a.xml", xml: s }],
        {},
        () => "worksheets/missing.xml",
      ),
    ),
    /invalid/,
  );
  await rejects(
    await zip(
      book(
        [{ part: "xl/worksheets/a.xml", xml: s }],
        {},
        () => "../../evil.xml",
      ),
    ),
    /invalid/,
  );
  await rejects(
    await zip(
      book(
        [{ part: "xl/worksheets/a.xml", xml: s }],
        {},
        () => "../docProps/app.xml",
      ),
    ),
    /invalid/,
  );
  const ext = book([{ part: "xl/worksheets/a.xml", xml: s }]);
  ext["xl/_rels/workbook.xml.rels"] =
    `<Relationships xmlns="${PKG}"><Relationship Id="rId1" Type="${XLSX_REL}" Target="http://x/y.xml" TargetMode="External"/></Relationships>`;
  await rejects(await zip(ext), /external links/);
});

Deno.test("malformed or unmatched row/cell markup fails instead of returning partial text", async () => {
  await rejects(
    await zip(
      one(
        `<worksheet xmlns="${MAIN}"><sheetData><row><c r="A1"><v>1</v></c></sheetData></worksheet>`,
      ),
    ),
    /malformed/,
  );
  await rejects(
    await zip(one(sheet(`<row><row><c r="A1"><v>1</v></c></row>`))),
    /malformed/,
  );
  await rejects(
    await zip(one(sheet(`<row><c r="1A"><v>1</v></c></row>`))),
    /invalid cell reference/,
  );
  await rejects(
    await zip(one(sheet(`<row><c r="A1" t="zz"><v>1</v></c></row>`))),
    /unsupported cell type/,
  );
});

Deno.test("hostile unmatched <row openings stay linear-time", async () => {
  // Varying attributes keep the part below the ratio guard so the parser itself is exercised.
  const xml = sheet(
    Array.from({ length: 120_000 }, (_, k) => `<row r="${k * 7919 % 1000003}">`)
      .join(""),
  );
  const started = performance.now();
  await rejects(await zip(one(xml)), /malformed/);
  if (performance.now() - started > 2000) {
    throw new Error("extraction was not linear");
  }
});

Deno.test("rejects non-zip, macros, external links, encrypted and DTD/entity content", async () => {
  await rejects(enc.encode("not a zip at all, plain text"), /not a valid/);
  await rejects(
    await zip(one(sheet(""), { "xl/vbaProject.bin": "x" })),
    /macros/,
  );
  await rejects(
    await zip(one(sheet(""), { "xl/externalLinks/externalLink1.xml": "x" })),
    /external links/,
  );
  await rejects(await zip(one(sheet("")), { flags: 1 }), /encrypted/);
  await rejects(
    await zip(
      one(
        `<!DOCTYPE x [<!ENTITY a "b">]>` +
          sheet(`<row><c r="A1"><v>1</v></c></row>`),
      ),
    ),
    /declarations/,
  );
});

Deno.test("rejects path traversal names, missing workbook parts, empty sheets", async () => {
  await rejects(
    await zip(one(sheet(""), { "../evil.xml": "x" })),
    /macros|not supported/,
  );
  const noRels = one(sheet(`<row><c r="A1"><v>1</v></c></row>`));
  delete (noRels as Record<string, string>)["xl/_rels/workbook.xml.rels"];
  await rejects(await zip(noRels), /not a valid/);
  await rejects(await zip(one(sheet(""))), /no readable/);
});

Deno.test("zip bomb, row, column and sheet limits fail closed (never truncate)", async () => {
  const bomb = `<worksheet xmlns="${MAIN}">` +
    "a".repeat(SPREADSHEET_LIMITS.maxPartInflatedBytes + 10) + "</worksheet>";
  await rejects(await zip(one(bomb)), /too large|ratio/);
  const manyRows = Array.from(
    { length: SPREADSHEET_LIMITS.maxRows + 1 },
    (_, i) => `<row><c r="A${i + 1}"><v>${i}</v></c></row>`,
  ).join("");
  await rejects(await zip(one(sheet(manyRows))), /too many rows/);
  await rejects(
    await zip(one(sheet(`<row><c r="AZ1"><v>1</v></c></row>`))),
    /too many columns/,
  );
  const four = [1, 2, 3, 4].map((n) => ({
    part: `xl/worksheets/sheet${n}.xml`,
    xml: sheet(`<row><c r="A1"><v>1</v></c></row>`),
  }));
  await rejects(await zip(book(four)), /too many sheets/);
});

Deno.test("bad shared-string index is an integrity failure, not a guess", async () => {
  await rejects(
    await zip(
      one(sheet(`<row><c r="A1" t="s"><v>9</v></c></row>`), {
        "xl/sharedStrings.xml": sst("a"),
      }),
    ),
    /inconsistent/,
  );
});

Deno.test("mismatched or crossed closing tags and unclosed elements fail instead of dropping text", async () => {
  const bad =
    `<worksheet xmlns="${MAIN}"><sheetData><row><c r="A1"><v>7</t>8</v></c></row></sheetData></worksheet>`;
  await rejects(await zip(one(bad)), /malformed/);
  await rejects(
    await zip(
      one(
        `<worksheet xmlns="${MAIN}"><sheetData><row><c r="A1"><v>1</v></c></row></sheetData>`,
      ),
    ),
    /malformed/,
  );
});

Deno.test("namespace identity is checked, not just the local name", async () => {
  // Foreign-namespace <row>/<c> must not be read as SpreadsheetML.
  const foreign = `<worksheet xmlns="${MAIN}" xmlns:f="urn:other"><sheetData>` +
    `<f:row><f:c r="A1"><f:v>666</f:v></f:c></f:row><row><c r="A1"><v>1</v></c></row></sheetData></worksheet>`;
  eq(await extractXlsxOrderText(await zip(one(foreign))), "1");
  // A worksheet in a non-SpreadsheetML default namespace is rejected, never read as an empty sheet.
  await rejects(
    await zip(
      one(
        `<worksheet xmlns="urn:other"><sheetData><row><c r="A1"><v>1</v></c></row></sheetData></worksheet>`,
      ),
    ),
    /unexpected root/,
  );
  // Unbound prefix and duplicate attributes are malformed.
  await rejects(
    await zip(
      one(
        `<worksheet xmlns="${MAIN}"><sheetData><q:row/></sheetData></worksheet>`,
      ),
    ),
    /malformed/,
  );
  await rejects(
    await zip(
      one(
        `<worksheet xmlns="${MAIN}"><sheetData><row><c r="A1" r="B1"><v>1</v></c></row></sheetData></worksheet>`,
      ),
    ),
    /malformed/,
  );
});

Deno.test("workbook sheet ids must use the officeDocument relationships namespace", async () => {
  const s = sheet(`<row><c r="A1"><v>1</v></c></row>`);
  const files = book([{ part: "xl/worksheets/a.xml", xml: s }]);
  files["xl/workbook.xml"] = files["xl/workbook.xml"].replace(
    RELNS,
    "urn:not-relationships",
  );
  await rejects(await zip(files), /relationship is missing/);
});

Deno.test("a worksheet with an unsupported root cannot be silently omitted next to a readable one", async () => {
  const good = sheet(`<row><c r="A1"><v>1</v></c></row>`);
  const foreignRoot =
    `<worksheet xmlns="urn:other"><sheetData><row><c r="A1"><v>2</v></c></row></sheetData></worksheet>`;
  await rejects(
    await zip(book([
      { part: "xl/worksheets/a.xml", xml: good },
      { part: "xl/worksheets/b.xml", xml: foreignRoot },
    ])),
    /unexpected root/,
  );
});

Deno.test("namespace tracking is bounded: deep nesting, many bindings and wide declarations", async () => {
  const deep = `<worksheet xmlns="${MAIN}"><sheetData>` +
    '<x:a xmlns:x="urn:x">'.repeat(200);
  await rejects(await zip(one(deep)), /nested too deeply/);
  const many = Array.from({ length: 80 }, (_, i) => `xmlns:p${i}="urn:${i}"`)
    .join(" ");
  await rejects(
    await zip(
      one(`<worksheet xmlns="${MAIN}" ${many}><sheetData/></worksheet>`),
    ),
    /too many namespaces/,
  );
  // Many siblings each declaring a namespace stay linear (copy cost is bounded).
  const wide = Array.from(
    { length: 20_000 },
    (_, i) =>
      `<row xmlns:q${i % 50}="urn:${i}"><c r="A1"><v>${i}</v></c></row>`,
  ).join("");
  const started = performance.now();
  await rejects(await zip(one(sheet(wide))), /too many rows/);
  if (performance.now() - started > 3000) {
    throw new Error("namespace handling was not linear");
  }
});
