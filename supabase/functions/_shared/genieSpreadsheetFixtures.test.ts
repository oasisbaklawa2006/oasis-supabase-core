import {
  extractXlsxOrderText,
  SpreadsheetExtractionError,
} from "./genieSpreadsheetText.ts";

const dir = new URL("./fixtures/genie-xlsx/", import.meta.url);
const load = (name: string) => Deno.readFile(new URL(name, dir));

const accepted: [string, string][] = [
  [
    "openpyxl_two_sheets.xlsx",
    "Product\tQty\tUnit\nकाजू कतली\t5\tkg\nPista Roll 500g\t2.5\tkg\nSparse item\t\tbox\nAlmond Baklawa\t10\tkg",
  ],
  [
    "xlsxwriter_formulas.xlsx",
    "Product\tQty\tUnit\tTotal\nKaju Katli\t4\tkg\t8\nबादाम बकलावा\t1.5\tkg\t3",
  ],
  [
    "lo_source.xlsx",
    "Product\tQty\tUnit\nकाजू कतली\t5\tkg\nPista Roll\t2.5\tkg\nAlmond Baklawa\t10\tkg",
  ],
  [
    "lo_recalculated_formulas.xlsx",
    "Product\tQty\tUnit\tTotal\nKaju Katli\t4\tkg\t8\nबादाम बकलावा\t1.5\tkg\t3",
  ],
];

for (const [file, expected] of accepted) {
  Deno.test(`fixture ${file} extracts the exact expected order text`, async () => {
    const actual = await extractXlsxOrderText(await load(file));
    if (actual !== expected) {
      throw new Error(
        `expected ${JSON.stringify(expected)} got ${JSON.stringify(actual)}`,
      );
    }
  });
}

const rejected: [string, RegExp][] = [
  ["openpyxl_hidden_sheet.xlsx", /hidden sheets/],
  ["truncated.xlsx", /not a valid/],
];

for (const [file, match] of rejected) {
  Deno.test(`fixture ${file} is rejected with an explicit error`, async () => {
    try {
      await extractXlsxOrderText(await load(file));
    } catch (e) {
      if (e instanceof SpreadsheetExtractionError && match.test(e.message)) {
        return;
      }
      throw e;
    }
    throw new Error("expected rejection");
  });
}
