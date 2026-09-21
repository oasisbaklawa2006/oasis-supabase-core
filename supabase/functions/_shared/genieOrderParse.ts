export type GenieParseMode = "text" | "audio" | "image" | "document";

export type GenieParseRequest = {
  mode: GenieParseMode;
  text?: string;
  mimeType?: string;
  fileName?: string;
  contentBase64?: string;
  locale: string;
};

export type GenieParseLine = {
  productName: string;
  quantity: number;
  uom: string;
};

const MAX_TEXT_LENGTH = 12_000;
const MAX_BASE64_LENGTH = 14_000_000;
const MAX_LINES = 100;

const IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);
const DOCUMENT_MIME = new Set([
  "application/pdf",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "text/plain",
  "text/csv",
]);
const AUDIO_MIME = new Set([
  "audio/mpeg",
  "audio/mp3",
  "audio/mp4",
  "audio/m4a",
  "audio/x-m4a",
  "audio/ogg",
  "audio/wav",
  "audio/x-wav",
  "audio/webm",
]);

function cleanText(value: unknown, max: number): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") throw new Error("invalid request field type");
  const out = value.trim();
  if (!out) return undefined;
  if (out.length > max) throw new Error("request field too large");
  return out;
}

export function parseGenieOrderRequest(value: unknown): GenieParseRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid request body");
  }
  const body = value as Record<string, unknown>;
  const mode = body.mode;
  if (mode !== "text" && mode !== "audio" && mode !== "image" && mode !== "document") {
    throw new Error("invalid parse mode");
  }

  const locale = cleanText(body.locale, 32) ?? "en-IN";
  const text = cleanText(body.text, MAX_TEXT_LENGTH);
  const mimeType = cleanText(body.mime_type, 120)?.toLowerCase();
  const fileName = cleanText(body.file_name, 240);
  const contentBase64 = cleanText(body.content_base64, MAX_BASE64_LENGTH);

  if (mode === "text") {
    if (!text) throw new Error("text is required");
    return { mode, text, locale };
  }

  if (!contentBase64 || !mimeType) {
    throw new Error("file content and mime type are required");
  }
  if (!/^[A-Za-z0-9+/=\r\n]+$/.test(contentBase64)) {
    throw new Error("invalid base64 content");
  }

  const allowed = mode === "image"
    ? IMAGE_MIME
    : mode === "audio"
    ? AUDIO_MIME
    : DOCUMENT_MIME;
  if (!allowed.has(mimeType)) throw new Error("unsupported file type");

  return {
    mode,
    contentBase64,
    mimeType,
    fileName: fileName ?? (mode === "image" ? "order-image" : mode === "audio" ? "voice-order" : "order-document"),
    locale,
  };
}

export const genieOrderJsonSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    lines: {
      type: "array",
      maxItems: MAX_LINES,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          productName: { type: "string", minLength: 1, maxLength: 200 },
          quantity: { type: "number", exclusiveMinimum: 0, maximum: 1_000_000 },
          uom: { type: "string", minLength: 1, maxLength: 40 },
        },
        required: ["productName", "quantity", "uom"],
      },
    },
  },
  required: ["lines"],
} as const;

export function validateGenieOrderOutput(value: unknown): GenieParseLine[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid model output");
  }
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((key) => key !== "lines") || !Array.isArray(record.lines)) {
    throw new Error("unexpected model output fields");
  }
  if (record.lines.length === 0) throw new Error("no explicit order lines found");
  if (record.lines.length > MAX_LINES) throw new Error("too many order lines");

  return record.lines.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("invalid order line");
    }
    const row = raw as Record<string, unknown>;
    const productName = typeof row.productName === "string" ? row.productName.trim() : "";
    const quantity = typeof row.quantity === "number" ? row.quantity : Number.NaN;
    const uom = typeof row.uom === "string" ? row.uom.trim() : "";
    if (!productName || productName.length > 200) throw new Error("invalid product name");
    if (!Number.isFinite(quantity) || quantity <= 0 || quantity > 1_000_000) {
      throw new Error("invalid quantity");
    }
    if (!uom || uom.length > 40) throw new Error("invalid uom");
    return { productName, quantity, uom };
  });
}

export function base64ToBytes(value: string): Uint8Array {
  let decoded: string;
  try {
    decoded = atob(value.replace(/\s+/g, ""));
  } catch {
    throw new Error("invalid base64 content");
  }
  const out = new Uint8Array(decoded.length);
  for (let i = 0; i < decoded.length; i += 1) out[i] = decoded.charCodeAt(i);
  return out;
}

export function audioFileExtension(mimeType: string): string {
  const normalized = mimeType.toLowerCase();
  if (normalized.includes("wav")) return "wav";
  if (normalized.includes("webm")) return "webm";
  if (normalized.includes("ogg")) return "ogg";
  if (normalized.includes("m4a") || normalized.includes("mp4")) return "m4a";
  return "mp3";
}
