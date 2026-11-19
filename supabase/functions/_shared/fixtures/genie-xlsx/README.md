# Genie XLSX fixtures — provenance

Synthetic order workbooks (no customer data). Each file records the tool that **actually produced it**.

| File | Origin | Expected |
| --- | --- | --- |
| `openpyxl_two_sheets.xlsx` | openpyxl 3.1.5 | two visible sheets, Hindi + English, decimal qty, embedded newline, sparse row |
| `openpyxl_hidden_sheet.xlsx` | openpyxl 3.1.5 | rejected: hidden sheet |
| `xlsxwriter_formulas.xlsx` | XlsxWriter 3.2.9 | formulas with cached values `8` and `3` |
| `lo_source.xlsx` | LibreOffice 24.2.7.2 headless convert of `lo_source.csv` | Hindi/English rows |
| `lo_recalculated_formulas.xlsx` | LibreOffice 24.2.7.2 headless re-save of `xlsxwriter_formulas.xlsx` | LibreOffice-recalculated values `8`, `3` |
| `truncated.xlsx` | first 3000 bytes of `lo_source.xlsx` | rejected: not a valid workbook |

**Not yet covered (explicitly pending):** Microsoft Excel desktop export and Google Sheets export. These must be
produced by those applications and added with their own provenance row; openpyxl/XlsxWriter/LibreOffice output is
not evidence of Excel or Sheets behaviour.
