# Genie XLSX fixtures — provenance

Synthetic order workbooks (no customer data). Each file records the tool that **actually produced it**.

| File | Origin | Expected |
| --- | --- | --- |
| `openpyxl_two_sheets.xlsx` | openpyxl 3.1.5 | two visible sheets, Hindi + English, decimal qty, embedded newline, sparse row |
| `openpyxl_hidden_sheet.xlsx` | openpyxl 3.1.5 | rejected: hidden sheet |
| `xlsxwriter_formulas.xlsx` | XlsxWriter 3.2.9 | formulas with cached values `8` and `3` |
| `lo_source.xlsx` | LibreOffice 24.2.7.2 headless convert of `lo_source.csv` | Hindi/English rows |
| `lo_recalculated_formulas.xlsx` | LibreOffice 24.2.7.2 headless re-save of `xlsxwriter_formulas.xlsx` | LibreOffice-recalculated values `8`, `3` |
| `gsheets_export_20261120.xlsx` | Native Google Sheets (authored 20 Nov 2026 IST, exported as XLSX via Google Drive connector); [synthetic source](https://docs.google.com/spreadsheets/d/1VG-ZmrplYrIfZIIB3_eMOjrRtZinj--hV9EV-zdy7-A/edit); Git blob `2a01da1336309dde2f5af7c4294e9d1a9417cf83` | Two visible worksheets; English/Hindi, decimals, sparse row, Unicode whitespace, multiline and a formula cached result of 10.5. The `TOTAL` row is source data and must never be auto-promoted into a priced order without reviewed line selection. |
| `truncated.xlsx` | first 3000 bytes of `lo_source.xlsx` | rejected: not a valid workbook |

**Not yet covered (explicitly pending):** Microsoft Excel desktop export. It must be produced by Excel and documented with its own provenance; synthetic openpyxl/XlsxWriter/LibreOffice/Google Sheets files are not Excel desktop evidence.

**Observed Google Sheets behaviour:** integer-valued numeric cells are stored in the XLSX as `9.0` (not `9`). The extractor
preserves the cached cell text exactly, so the expected output for this fixture contains `9.0`; this is faithful to the file and
resolves to the same quantity downstream. Found by running the authentic export against the merged parser (the draft test had
assumed `9`).
