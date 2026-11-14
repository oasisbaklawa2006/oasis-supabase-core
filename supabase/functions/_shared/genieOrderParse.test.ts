import {
  buildGenieTextPrompt,
  extractResponsesText,
  normalizeGenieMimeType,
  parseGenieOrderRequest,
  validateGenieOrderLines,
} from "./genieOrderParse.ts";

Deno.test("parseGenieOrderRequest accepts governed text", () => {
  const parsed = parseGenieOrderRequest({
    mode: "text",
    text: "20 boxes pistachio baklawa",
    locale: "en-IN",
  });
  if (parsed.mode !== "text" || parsed.text !== "20 boxes pistachio baklawa") {
    throw new Error("unexpected parse");
  }
});

Deno.test("parseGenieOrderRequest requires quantity-bearing source content rather than local defaults", () => {
  let threw = false;
  try {
    parseGenieOrderRequest({ mode: "text", text: "   " });
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("blank text should fail");
});

Deno.test("parseGenieOrderRequest requires base64 for media modes", () => {
  for (const mode of ["audio", "image", "document"] as const) {
    let threw = false;
    try {
      parseGenieOrderRequest({ mode });
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`${mode} without content should fail`);
  }
});

Deno.test("parseGenieOrderRequest rejects malformed base64 before provider invocation", () => {
  for (const contentBase64 of ["====", "not base64!", "abc"]) {
    let threw = false;
    try {
      parseGenieOrderRequest({
        mode: "image",
        mime_type: "image/png",
        content_base64: contentBase64,
      });
    } catch {
      threw = true;
    }
    if (!threw) {
      throw new Error(`malformed base64 should fail: ${contentBase64}`);
    }
  }
});

Deno.test("parseGenieOrderRequest normalizes valid base64 and mime type", () => {
  const parsed = parseGenieOrderRequest({
    mode: "image",
    mime_type: "IMAGE/PNG",
    content_base64: "iVBO\nRw0KGgo=",
  });
  if (
    parsed.contentBase64 !== "iVBORw0KGgo=" || parsed.mimeType !== "image/png"
  ) {
    throw new Error("media normalization failed");
  }
});

Deno.test("parser rejects fake PDF/PNG and empty media", () => {
  for (
    const [mode, mimeType, contentBase64] of [
      ["document", "application/pdf", btoa("not really a PDF")],
      ["image", "image/png", btoa("not really a PNG")],
      ["image", "image/jpeg", btoa("not really JPEG")],
      ["audio", "audio/wav", btoa("not really WAV")],
      ["document", "application/pdf", btoa("")],
    ] as const
  ) {
    let threw = false;
    try {
      parseGenieOrderRequest({
        mode,
        mime_type: mimeType,
        content_base64: contentBase64,
      });
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`spoofed or empty ${mimeType} must be denied`);
  }
});

Deno.test("parser accepts PDF/JPEG signature headers as preflight only", () => {
  const pdf = parseGenieOrderRequest({
    mode: "document",
    mime_type: "application/pdf",
    content_base64: btoa("%PDF-1.7\n"),
  });
  const jpeg = parseGenieOrderRequest({
    mode: "image",
    mime_type: "image/jpeg",
    content_base64: btoa(String.fromCharCode(0xff, 0xd8, 0xff, 0xe0)),
  });
  if (pdf.mimeType !== "application/pdf" || jpeg.mimeType !== "image/jpeg") {
    throw new Error("valid evidence signatures rejected");
  }
});

Deno.test("Genie rejects MP4/unknown and truncated boxes labelled as HEIC or AVIF", () => {
  const asBox = (brand: string, size = 16): string => {
    const header = [0, 0, 0, size, 0x66, 0x74, 0x79, 0x70];
    const content = [...brand].map((letter) => letter.charCodeAt(0));
    return btoa(String.fromCharCode(...header, ...content, 0, 0, 0, 0));
  };
  for (
    const [mime, body] of [
      ["image/heic", asBox("mp42")],
      ["image/avif", asBox("mp42")],
      ["image/heic", asBox("heic", 32)],
      ["image/avif", asBox("avif", 8)],
      ["image/avif", "AAAAAGZ0eXA="],
    ]
  ) {
    let rejected = false;
    try {
      parseGenieOrderRequest({
        mode: "image",
        mime_type: mime,
        content_base64: body,
      });
    } catch {
      rejected = true;
    }
    if (!rejected) {
      throw new Error(`non-image/truncated ISO BMFF box accepted as ${mime}`);
    }
  }
});

Deno.test("Genie allows preflight-compatible HEIC and AVIF ftyp brands", () => {
  const box = (brand: string): string =>
    btoa(
      String.fromCharCode(
        0,
        0,
        0,
        16,
        0x66,
        0x74,
        0x79,
        0x70,
        ...[...brand].map((x) => x.charCodeAt(0)),
        0,
        0,
        0,
        0,
      ),
    );
  for (
    const [mime, brand] of [["image/heic", "heic"], ["image/avif", "avif"], [
      "image/heif",
      "mif1",
    ]]
  ) {
    const parsed = parseGenieOrderRequest({
      mode: "image",
      mime_type: mime,
      content_base64: box(brand),
    });
    if (parsed.mimeType !== mime) {
      throw new Error(`valid ftyp image brand ${brand} rejected`);
    }
  }
});

Deno.test("Genie accepts registered HEIC still brands and 64-bit ftyp sizes", () => {
  const normalBrand = (brand: string) =>
    btoa(
      String.fromCharCode(
        0,
        0,
        0,
        16,
        0x66,
        0x74,
        0x79,
        0x70,
        ...[...brand].map((x) => x.charCodeAt(0)),
        0,
        0,
        0,
        0,
      ),
    );
  for (const brand of ["heic", "heix", "heim", "heis"]) {
    const parsed = parseGenieOrderRequest({
      mode: "image",
      mime_type: "image/heic",
      content_base64: normalBrand(brand),
    });
    if (parsed.mimeType !== "image/heic") {
      throw new Error("registered still brand rejected");
    }
  }
  let sequenceAccepted = false;
  try {
    parseGenieOrderRequest({
      mode: "image",
      mime_type: "image/heic",
      content_base64: normalBrand("hevc"),
    });
    sequenceAccepted = true;
  } catch { /* image sequence is not a still-image MIME match */ }
  if (sequenceAccepted) {
    throw new Error("HEVC sequence brand accepted as HEIC still image");
  }

  const ext = new Uint8Array(24);
  ext.set([0, 0, 0, 1, 0x66, 0x74, 0x79, 0x70], 0);
  ext[15] = 24; // 64-bit box length
  ext.set([...("avif")].map((x) => x.charCodeAt(0)), 16);
  const b64 = btoa(String.fromCharCode(...ext));
  const parsed = parseGenieOrderRequest({
    mode: "image",
    mime_type: "image/avif",
    content_base64: b64,
  });
  if (parsed.mimeType !== "image/avif") {
    throw new Error("valid extended-size AVIF ftyp rejected");
  }

  const large = new Uint8Array(4100);
  large.set([0, 0, 16, 4, 0x66, 0x74, 0x79, 0x70], 0); // ftyp boxSize = 4100
  large.set([...("heic")].map((x) => x.charCodeAt(0)), 8);
  const bytes = [...large].map((x) => String.fromCharCode(x)).join("");
  const largeParsed = parseGenieOrderRequest({
    mode: "image",
    mime_type: "image/heic",
    content_base64: btoa(bytes),
  });
  if (largeParsed.mimeType !== "image/heic") {
    throw new Error("large valid HEIC ftyp rejected");
  }
});

Deno.test("Genie rejects misaligned 64-bit ftyp boxes for both image and audio", () => {
  for (
    const [mime, mode, brand] of [
      ["image/avif", "image", "avif"],
      ["audio/mp4", "audio", "M4A "],
    ] as const
  ) {
    const bytes = new Uint8Array(25);
    bytes.set([0, 0, 0, 1, 0x66, 0x74, 0x79, 0x70], 0);
    bytes[15] = 25;
    bytes.set([...brand].map((value) => value.charCodeAt(0)), 16);
    let accepted = false;
    try {
      parseGenieOrderRequest({
        mode,
        mime_type: mime,
        content_base64: btoa(String.fromCharCode(...bytes)),
      });
      accepted = true;
    } catch { /* malformed ftyp is invalid */ }
    if (accepted) {
      throw new Error(`misaligned extended ftyp accepted as ${mime}`);
    }
  }
});

Deno.test("Genie accepts M4A audio advertised only as a compatible ftyp brand", () => {
  const bytes = new Uint8Array(24);
  bytes.set([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70], 0);
  bytes.set([...("isom")].map((value) => value.charCodeAt(0)), 8);
  bytes.set([...("M4A ")].map((value) => value.charCodeAt(0)), 20);
  const encoded = btoa(String.fromCharCode(...bytes));
  for (const mime of ["audio/mp4", "audio/x-m4a", "audio/m4a"]) {
    const parsed = parseGenieOrderRequest({
      mode: "audio",
      mime_type: mime,
      content_base64: encoded,
    });
    if (parsed.mimeType !== mime) {
      throw new Error(`compatible M4A ftyp brand rejected for ${mime}`);
    }
  }
});

Deno.test("Genie rejects spoofed WAV MIME aliases consistently", () => {
  for (
    const mime of [
      "audio/wav",
      "audio/x-wav",
      "audio/wave",
      "audio/x-pn-wav",
      "audio/vnd.wave",
      "video/audio/wav",
    ]
  ) {
    let rejected = false;
    try {
      parseGenieOrderRequest({
        mode: "audio",
        mime_type: mime,
        content_base64: btoa("not a wave"),
      });
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`non-WAV payload accepted as ${mime}`);
  }
  const validHeader = btoa("RIFF" + String.fromCharCode(0, 0, 0, 0) + "WAVE");
  for (const mime of ["audio/wav", "audio/wave", "audio/x-pn-wav"]) {
    const parsed = parseGenieOrderRequest({
      mode: "audio",
      mime_type: mime,
      content_base64: validHeader,
    });
    if (parsed.mimeType !== mime) {
      throw new Error(`WAVE signature should pass for ${mime}`);
    }
  }
});

Deno.test("Genie rejects wrong bytes for all approved encoded audio MIME types", () => {
  for (
    const mime of [
      "audio/mpeg",
      "audio/mp3",
      "audio/ogg",
      "audio/opus",
      "audio/webm",
      "audio/flac",
      "audio/aac",
      "audio/mp4",
      "audio/x-m4a",
      "audio/m4a",
    ]
  ) {
    let rejected = false;
    try {
      parseGenieOrderRequest({
        mode: "audio",
        mime_type: mime,
        content_base64: btoa("not a valid audio recording"),
      });
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error(`fake audio accepted as ${mime}`);
  }
  for (const unsupported of ["audio/unknown", "audio/amr", "audio/basic"]) {
    let rejected = false;
    try {
      normalizeGenieMimeType("audio", unsupported);
    } catch {
      rejected = true;
    }
    if (!rejected) {
      throw new Error(`unsupported format accepted: ${unsupported}`);
    }
  }
});

Deno.test("Genie rejects forged or truncated M4A ftyp box sizes for every audio alias", () => {
  const box = (size: number, actualLength = 16): string => {
    const bytes = new Uint8Array(actualLength);
    bytes.set([0, 0, 0, size, 0x66, 0x74, 0x79, 0x70]);
    bytes.set([...("M4A ")].map((x) => x.charCodeAt(0)), 8);
    return btoa(String.fromCharCode(...bytes));
  };
  for (const mime of ["audio/mp4", "audio/x-m4a", "audio/m4a"]) {
    for (
      const body of [
        box(0),
        box(8),
        box(12),
        box(20),
        box(32),
        box(16, 12),
      ]
    ) {
      let accepted = false;
      try {
        parseGenieOrderRequest({
          mode: "audio",
          mime_type: mime,
          content_base64: body,
        });
        accepted = true;
      } catch { /* invalid or truncated ftyp must fail preflight */ }
      if (accepted) {
        throw new Error(`forged or truncated M4A ftyp box accepted: ${mime}`);
      }
    }
  }
});

Deno.test("Genie accepts valid M4A extended ftyp and refuses oversized declared bounds", () => {
  const ext = new Uint8Array(24);
  ext.set([0, 0, 0, 1, 0x66, 0x74, 0x79, 0x70], 0);
  ext[15] = 24;
  ext.set([...("M4A ")].map((x) => x.charCodeAt(0)), 16);
  const accepted = parseGenieOrderRequest({
    mode: "audio",
    mime_type: "audio/mp4",
    content_base64: btoa(String.fromCharCode(...ext)),
  });
  if (accepted.mimeType !== "audio/mp4") {
    throw new Error("valid extended-size M4A header rejected");
  }
  ext[15] = 32;
  let rejected = false;
  try {
    parseGenieOrderRequest({
      mode: "audio",
      mime_type: "audio/mp4",
      content_base64: btoa(String.fromCharCode(...ext)),
    });
  } catch {
    rejected = true;
  }
  if (!rejected) {
    throw new Error("extended M4A box size larger than actual bytes accepted");
  }
});

Deno.test("Genie allows the guarded header signatures of supported audio formats", () => {
  const examples: Array<[string, string]> = [
    ["audio/mpeg", "ID3" + String.fromCharCode(3, 0, 0, 0)],
    ["audio/mp3", String.fromCharCode(0xff, 0xfb, 0x90, 0x64)],
    ["audio/ogg", "OggS" + String.fromCharCode(0)],
    ["audio/opus", "OggS" + String.fromCharCode(0)],
    ["audio/webm", String.fromCharCode(0x1a, 0x45, 0xdf, 0xa3)],
    ["audio/flac", "fLaC"],
    ["audio/aac", String.fromCharCode(0xff, 0xf1, 0x50, 0x80)],
    [
      "audio/mp4",
      String.fromCharCode(0, 0, 0, 16) + "ftypM4A " +
      String.fromCharCode(0, 0, 0, 0),
    ],
    [
      "audio/x-m4a",
      String.fromCharCode(0, 0, 0, 16) + "ftypM4A " +
      String.fromCharCode(0, 0, 0, 0),
    ],
    [
      "audio/m4a",
      String.fromCharCode(0, 0, 0, 16) + "ftypM4A " +
      String.fromCharCode(0, 0, 0, 0),
    ],
  ];
  for (const [mime, bytes] of examples) {
    const parsed = parseGenieOrderRequest({
      mode: "audio",
      mime_type: mime,
      content_base64: btoa(bytes),
    });
    if (parsed.mimeType !== mime) {
      throw new Error(`recognized audio prefix rejected: ${mime}`);
    }
  }
  const raw = new Uint8Array(512);
  const parsed = parseGenieOrderRequest({
    mode: "audio",
    mime_type: "video/audio/s16le",
    content_base64: btoa(String.fromCharCode(...raw)),
  });
  if (parsed.mimeType !== "video/audio/s16le") {
    throw new Error("raw 16-bit audio compatibility rejected");
  }
  let rejected = false;
  try {
    parseGenieOrderRequest({
      mode: "audio",
      mime_type: "video/audio/s16le",
      content_base64: btoa("short malformed PCM"),
    });
  } catch {
    rejected = true;
  }
  if (!rejected) {
    throw new Error("unaligned or undersized raw-audio payload accepted");
  }
});

Deno.test("normalizeGenieMimeType enforces media-mode boundaries", () => {
  if (normalizeGenieMimeType("image", "image/png") !== "image/png") {
    throw new Error("png should be accepted");
  }
  if (normalizeGenieMimeType("audio", "audio/wav") !== "audio/wav") {
    throw new Error("wav should be accepted");
  }
  if (
    normalizeGenieMimeType("document", "application/pdf") !== "application/pdf"
  ) {
    throw new Error("pdf should be accepted");
  }

  for (
    const [mode, mimeType] of [
      ["image", "audio/wav"],
      ["audio", "image/png"],
      ["document", "application/vnd.ms-excel"],
    ] as const
  ) {
    let threw = false;
    try {
      normalizeGenieMimeType(mode, mimeType);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`${mimeType} should be rejected for ${mode}`);
  }
});

Deno.test("validateGenieOrderLines rejects zero or invented default quantity", () => {
  let threw = false;
  try {
    validateGenieOrderLines({
      lines: [{ productName: "Baklawa", quantity: 0, uom: "box" }],
    });
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("zero quantity should fail");
});

Deno.test("validateGenieOrderLines normalizes safe lines only", () => {
  const lines = validateGenieOrderLines({
    lines: [{ productName: " Pistachio Baklawa ", quantity: 12, uom: " box " }],
  });
  if (
    lines.length !== 1 ||
    lines[0].productName !== "Pistachio Baklawa" ||
    lines[0].uom !== "box"
  ) {
    throw new Error("normalization failed");
  }
});

Deno.test("buildGenieTextPrompt embeds no-invention rules", () => {
  const prompt = buildGenieTextPrompt({
    text: "10 box kaju baklawa",
    locale: "en-IN",
  });
  if (
    !prompt.includes("Never invent") || !prompt.includes("10 box kaju baklawa")
  ) {
    throw new Error("prompt guard missing");
  }
});

Deno.test("extractResponsesText reads structured response text", () => {
  const text = extractResponsesText({
    output: [{ content: [{ type: "output_text", text: '{"lines":[]}' }] }],
  });
  if (text !== '{"lines":[]}') throw new Error("response extraction failed");
});
