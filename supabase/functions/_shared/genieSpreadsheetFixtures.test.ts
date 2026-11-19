import {
  extractXlsxOrderText,
  SpreadsheetExtractionError,
} from "./genieSpreadsheetText.ts";

const dir = new URL("./fixtures/genie-xlsx/", import.meta.url);
const load = (name: string) => Deno.readFile(new URL(name, dir));

const accepted: [string, string][] = [
  [
    "gsheets_export_20261120.xlsx",
    [
      "SKU\tProduct\tQuantity\tUnit\tNotes",
      "GENIE-UAT-CAJU\tSynthetic Genie Cashew\t9.0\tkg\tकाजू / English order; keep 9 kg",
      "GENIE-UAT-PISTA\tSynthetic Genie Pista\t1.5\tkg\tHalf quantity; seek clarification",
      "TOTAL\tsynthetic only\t10.5\tkg\tFormula result is not an additional order line",
      "Language\tInstruction",
      "हिन्दी\tऑर्डर: ९ किलो काजू — सत्यापन करें",
      "English\tPlease verify the quantity and UOM before Cart acceptance",
      "Mixed script\tकाजू 9 kg — do not silently change to a carton MOQ",
      "Multiline\tLine one Line two",
      "Encoded whitespace\tSpace and NBSP thin space",
    ].join("\n"),
  ],
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
