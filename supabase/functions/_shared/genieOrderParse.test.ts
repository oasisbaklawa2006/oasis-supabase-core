import {
  buildGenieTextPrompt,
  extractResponsesText,
  parseGenieOrderRequest,
  validateGenieOrderLines,
} from "./genieOrderParse.ts";

Deno.test("parseGenieOrderRequest accepts governed text", () => {
  const parsed = parseGenieOrderRequest({ mode: "text", text: "20 boxes pistachio baklawa", locale: "en-IN" });
  if (parsed.mode !== "text" || parsed.text !== "20 boxes pistachio baklawa") throw new Error("unexpected parse");
});

Deno.test("parseGenieOrderRequest requires quantity-bearing source content rather than local defaults", () => {
  let threw = false;
  try { parseGenieOrderRequest({ mode: "text", text: "   " }); } catch { threw = true; }
  if (!threw) throw new Error("blank text should fail");
});

Deno.test("parseGenieOrderRequest requires base64 for media modes", () => {
  for (const mode of ["audio", "image", "document"] as const) {
    let threw = false;
    try { parseGenieOrderRequest({ mode }); } catch { threw = true; }
    if (!threw) throw new Error(`${mode} without content should fail`);
  }
});

Deno.test("validateGenieOrderLines rejects zero or invented default quantity", () => {
  let threw = false;
  try {
    validateGenieOrderLines({ lines: [{ productName: "Baklawa", quantity: 0, uom: "box" }] });
  } catch { threw = true; }
  if (!threw) throw new Error("zero quantity should fail");
});

Deno.test("validateGenieOrderLines normalizes safe lines only", () => {
  const lines = validateGenieOrderLines({
    lines: [{ productName: " Pistachio Baklawa ", quantity: 12, uom: " box " }],
  });
  if (lines.length !== 1 || lines[0].productName !== "Pistachio Baklawa" || lines[0].uom !== "box") {
    throw new Error("normalization failed");
  }
});

Deno.test("buildGenieTextPrompt embeds no-invention rules", () => {
  const prompt = buildGenieTextPrompt({ text: "10 box kaju baklawa", locale: "en-IN" });
  if (!prompt.includes("Never invent") || !prompt.includes("10 box kaju baklawa")) throw new Error("prompt guard missing");
});

Deno.test("extractResponsesText reads structured response text", () => {
  const text = extractResponsesText({ output: [{ content: [{ type: "output_text", text: "{\"lines\":[]}" }] }] });
  if (text !== '{"lines":[]}') throw new Error("response extraction failed");
});
