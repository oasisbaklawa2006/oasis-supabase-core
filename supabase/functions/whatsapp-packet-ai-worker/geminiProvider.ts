/** @file Direct Gemini multimodal provider adapter for governed WhatsApp evidence. */

export const GEMINI_MODEL = "gemini-3.7-flash";
export const GEMINI_GENERATE_CONTENT_URL =
  `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;

export type GeminiPart =
  | { text: string }
  | { inlineData: { mimeType: string; data: string } };

export type GeminiRequest = {
  contents: Array<{ role: "user"; parts: GeminiPart[] }>;
  generationConfig: {
    responseMimeType: "application/json";
    temperature: 0;
    maxOutputTokens: number;
  };
};

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(
      ...bytes.subarray(offset, Math.min(offset + chunk, bytes.length)),
    );
  }
  return btoa(binary);
}

export function textPart(text: string): GeminiPart {
  return { text };
}

export function inlineMediaPart(
  bytes: Uint8Array,
  mimeType: string,
): GeminiPart {
  return {
    inlineData: {
      mimeType,
      data: bytesToBase64(bytes),
    },
  };
}

export function buildGeminiRequest(parts: GeminiPart[]): GeminiRequest {
  return {
    contents: [{ role: "user", parts }],
    generationConfig: {
      responseMimeType: "application/json",
      temperature: 0,
      maxOutputTokens: 3600,
    },
  };
}

export function parseGeminiJsonText(payload: unknown): string {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("INTERPRETER_PROVIDER_MALFORMED");
  }
  const record = payload as Record<string, unknown>;
  const candidates = Array.isArray(record.candidates) ? record.candidates : [];
  const first = candidates[0];
  if (!first || typeof first !== "object" || Array.isArray(first)) {
    throw new Error("INTERPRETER_EMPTY_RESPONSE");
  }
  const content = (first as Record<string, unknown>).content;
  if (!content || typeof content !== "object" || Array.isArray(content)) {
    throw new Error("INTERPRETER_PROVIDER_MALFORMED");
  }
  const parts = Array.isArray((content as Record<string, unknown>).parts)
    ? (content as Record<string, unknown>).parts as unknown[]
    : [];
  const text = parts
    .map((part) => {
      if (!part || typeof part !== "object" || Array.isArray(part)) return "";
      const value = (part as Record<string, unknown>).text;
      return typeof value === "string" ? value : "";
    })
    .join("")
    .trim();
  if (!text) throw new Error("INTERPRETER_EMPTY_RESPONSE");
  return text;
}

export async function callGeminiGenerateContent(
  apiKey: string,
  request: GeminiRequest,
  fetchImpl: typeof fetch = fetch,
): Promise<string> {
  if (!apiKey) throw new Error("WORKER_NOT_CONFIGURED");
  let response: Response;
  try {
    response = await fetchImpl(GEMINI_GENERATE_CONTENT_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-goog-api-key": apiKey,
      },
      signal: AbortSignal.timeout(45_000),
      body: JSON.stringify(request),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "TimeoutError") {
      throw new Error("INTERPRETER_PROVIDER_TIMEOUT");
    }
    throw new Error("INTERPRETER_PROVIDER_TRANSPORT");
  }
  if (!response.ok) {
    throw new Error(`INTERPRETER_PROVIDER_${response.status}`);
  }
  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new Error("INTERPRETER_PROVIDER_MALFORMED");
  }
  return parseGeminiJsonText(payload);
}
