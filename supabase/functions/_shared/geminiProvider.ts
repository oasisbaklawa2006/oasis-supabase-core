/** @file Direct Gemini multimodal provider adapter for governed WhatsApp evidence. */

import { isTransientHttpStatus } from "./integrationRetryContract.ts";

export const GEMINI_MODEL = "gemini-3.6-flash";
export const GEMINI_TIMEOUT_MS = 90_000;
export const GEMINI_MAX_ATTEMPTS = 3;
export const GEMINI_RETRY_DELAYS_MS = [750, 2_000] as const;
export const GEMINI_GENERATE_CONTENT_URL =
  `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;

export type GeminiPart =
  | { text: string }
  | { inlineData: { mimeType: string; data: string } };

export type GeminiRequest = {
  contents: Array<{ role: "user"; parts: GeminiPart[] }>;
  generationConfig: {
    responseMimeType: "application/json";
    maxOutputTokens: number;
  };
};

type Sleep = (milliseconds: number) => Promise<void>;
type Now = () => number;

/** Encodes bounded governed media bytes for Gemini inlineData. */
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

/** Builds a Gemini text part without changing evidence text. */
export function textPart(text: string): GeminiPart {
  return { text };
}

/** Builds a Gemini inline media part while preserving the governed MIME type. */
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

/** Builds the bounded JSON-mode Gemini GenerateContent request. */
export function buildGeminiRequest(parts: GeminiPart[]): GeminiRequest {
  if (!parts.length) throw new Error("INTERPRETER_REQUEST_EMPTY");
  return {
    contents: [{ role: "user", parts }],
    generationConfig: {
      responseMimeType: "application/json",
      maxOutputTokens: 3600,
    },
  };
}

/** Removes a single optional Markdown JSON fence without altering JSON content. */
function stripOptionalJsonFence(value: string): string {
  const trimmed = value.trim();
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  return fenced ? fenced[1].trim() : trimmed;
}

/** Extracts the first Gemini candidate's textual response and fails closed on malformed/empty payloads. */
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
  const normalized = stripOptionalJsonFence(text);
  if (!normalized) throw new Error("INTERPRETER_EMPTY_RESPONSE");
  return normalized;
}

/** Returns true only for provider failures that are safe to retry without changing authority. */
export function isTransientGeminiStatus(status: number): boolean {
  return isTransientHttpStatus(status);
}

const defaultSleep: Sleep = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

/** Calls Gemini directly with a transferable provider key and bounded transient retries. */
export async function callGeminiGenerateContent(
  apiKey: string,
  request: GeminiRequest,
  fetchImpl: typeof fetch = fetch,
  sleepImpl: Sleep = defaultSleep,
  nowImpl: Now = Date.now,
): Promise<string> {
  if (!apiKey) throw new Error("WORKER_NOT_CONFIGURED");
  const startedAt = nowImpl();
  let lastTransientStatus: number | null = null;

  for (let attempt = 0; attempt < GEMINI_MAX_ATTEMPTS; attempt += 1) {
    const remainingMs = GEMINI_TIMEOUT_MS - (nowImpl() - startedAt);
    if (remainingMs <= 0) {
      if (lastTransientStatus !== null) {
        throw new Error(`INTERPRETER_PROVIDER_${lastTransientStatus}`);
      }
      throw new Error("INTERPRETER_PROVIDER_TIMEOUT");
    }

    let response: Response;
    try {
      response = await fetchImpl(GEMINI_GENERATE_CONTENT_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
        },
        signal: AbortSignal.timeout(Math.max(1, remainingMs)),
        body: JSON.stringify(request),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new Error("INTERPRETER_PROVIDER_TIMEOUT");
      }
      throw new Error("INTERPRETER_PROVIDER_TRANSPORT");
    }

    if (response.ok) {
      let payload: unknown;
      try {
        payload = await response.json();
      } catch {
        throw new Error("INTERPRETER_PROVIDER_MALFORMED");
      }
      return parseGeminiJsonText(payload);
    }

    const status = response.status;
    if (!isTransientGeminiStatus(status)) {
      throw new Error(`INTERPRETER_PROVIDER_${status}`);
    }
    lastTransientStatus = status;

    if (attempt >= GEMINI_MAX_ATTEMPTS - 1) {
      throw new Error(`INTERPRETER_PROVIDER_${status}`);
    }

    const delayMs = GEMINI_RETRY_DELAYS_MS[attempt] ??
      GEMINI_RETRY_DELAYS_MS[GEMINI_RETRY_DELAYS_MS.length - 1];
    const remainingAfterResponse = GEMINI_TIMEOUT_MS - (nowImpl() - startedAt);
    if (remainingAfterResponse <= delayMs) {
      throw new Error(`INTERPRETER_PROVIDER_${status}`);
    }

    await response.body?.cancel().catch(() => undefined);
    await sleepImpl(delayMs);
  }

  throw new Error(
    lastTransientStatus === null
      ? "INTERPRETER_PROVIDER_TRANSPORT"
      : `INTERPRETER_PROVIDER_${lastTransientStatus}`,
  );
}
