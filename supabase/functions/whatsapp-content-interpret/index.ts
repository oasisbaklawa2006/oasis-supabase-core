import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const DEVANAGARI = /[\u0900-\u097F]/;

type InterpretResponse = {
  normalized_text: string;
  extracted_text: string;
  language: string;
  confidence: number;
  warnings: string[];
  source_kind: "text" | "image";
};

function respond(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

function clampConfidence(value: unknown): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(1, n));
}

function sanitizeResult(raw: unknown, sourceKind: "text" | "image"): InterpretResponse {
  const obj = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  const normalizedText = typeof obj.normalized_text === "string" ? obj.normalized_text.trim().slice(0, 6000) : "";
  const extractedText = typeof obj.extracted_text === "string" ? obj.extracted_text.trim().slice(0, 6000) : "";
  const language = typeof obj.language === "string" ? obj.language.trim().slice(0, 80) : "unknown";
  const warnings = Array.isArray(obj.warnings)
    ? obj.warnings.filter((value): value is string => typeof value === "string").map((value) => value.slice(0, 240)).slice(0, 12)
    : [];
  return {
    normalized_text: normalizedText,
    extracted_text: extractedText,
    language,
    confidence: clampConfidence(obj.confidence),
    warnings,
    source_kind: sourceKind,
  };
}

async function callInterpreter(params: {
  apiKey: string;
  text?: string;
  imageDataUrl?: string;
}): Promise<InterpretResponse> {
  const sourceKind = params.imageDataUrl ? "image" : "text";
  const prompt = sourceKind === "image"
    ? `Read this WhatsApp order image as business evidence for Oasis Baklawa. Extract only facts that are explicitly visible. Preserve product names, SKU codes, quantities, units, corrections and Hindi/English wording. Translate or transliterate Hindi into concise English for downstream matching, but never invent a product, quantity, unit, customer, price or delivery promise. If a character or fact is unclear, omit it from normalized_text and add a warning. Return JSON only with: {"normalized_text":"literal order text suitable for product/quantity matching","extracted_text":"faithful visible text, preserving the original language where possible","language":"detected language(s)","confidence":0.0,"warnings":[]}.`
    : `Normalize this WhatsApp business message for Oasis Baklawa order matching. The source may be Hindi, Hinglish or English. Preserve every explicit product name, SKU, quantity, unit and correction. Translate/transliterate Hindi into concise English, but do not add or infer any product, quantity, unit, customer, price or delivery promise that is not explicitly present. If something is ambiguous, preserve the ambiguity and add a warning. Return JSON only with: {"normalized_text":"literal normalized text suitable for product/quantity matching","extracted_text":"the original text unchanged","language":"detected language(s)","confidence":0.0,"warnings":[]}.

SOURCE TEXT:\n${(params.text ?? "").slice(0, 6000)}`;

  const content: Array<Record<string, unknown>> = [{ type: "text", text: prompt }];
  if (params.imageDataUrl) {
    content.push({ type: "image_url", image_url: { url: params.imageDataUrl } });
  }

  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${params.apiKey}`,
    },
    body: JSON.stringify({
      model: "google/gemini-3-flash-preview",
      messages: [{ role: "user", content }],
      response_format: { type: "json_object" },
      max_tokens: 1400,
      temperature: 0,
    }),
  });

  if (!response.ok) {
    await response.text();
    throw new Error(`INTERPRETER_PROVIDER_${response.status}`);
  }
  const payload = await response.json();
  const rawContent = payload?.choices?.[0]?.message?.content;
  if (typeof rawContent !== "string" || !rawContent.trim()) {
    throw new Error("INTERPRETER_EMPTY_RESPONSE");
  }
  return sanitizeResult(JSON.parse(rawContent), sourceKind);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return respond({ success: false, error: "AUTH_REQUIRED" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) {
    return respond({ success: false, error: "SUPABASE_CONFIG_MISSING" }, 500);
  }

  const scoped = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await scoped.auth.getUser();
  if (authError || !authData.user) return respond({ success: false, error: "AUTH_INVALID" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return respond({ success: false, error: "INVALID_JSON" }, 400);
  }
  const providerMessageId = typeof body.provider_message_id === "string" ? body.provider_message_id.trim() : "";
  if (!providerMessageId) return respond({ success: false, error: "PROVIDER_MESSAGE_ID_REQUIRED" }, 400);

  // Use the caller's RLS-scoped client to establish both existence and wa.intake.read authority.
  const { data: message, error: messageError } = await scoped
    .from("whatsapp_messages")
    .select("provider_message_id, content, message_type, media_url, direction")
    .eq("provider_message_id", providerMessageId)
    .eq("direction", "inbound")
    .maybeSingle();
  if (messageError) return respond({ success: false, error: "MESSAGE_LOOKUP_FAILED" }, 500);
  if (!message) return respond({ success: false, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" }, 404);

  const sourceText = typeof message.content === "string" ? message.content : "";
  const messageType = typeof message.message_type === "string" ? message.message_type.toLowerCase() : "text";
  const mediaUrl = typeof message.media_url === "string" ? message.media_url : "";
  const shouldReadImage = messageType === "image" && !!mediaUrl;
  const shouldNormalizeHindi = DEVANAGARI.test(sourceText);

  if (!shouldReadImage && !shouldNormalizeHindi) {
    return respond({
      success: true,
      interpretation: {
        normalized_text: sourceText,
        extracted_text: sourceText,
        language: "not_required",
        confidence: 1,
        warnings: [],
        source_kind: "text",
      },
    });
  }

  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!apiKey) return respond({ success: false, error: "INTERPRETER_NOT_CONFIGURED" }, 503);

  try {
    if (shouldReadImage) {
      const click2ApiKey = Deno.env.get("CLICK2API_API_KEY");
      const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
      const mediaResponse = await fetch(mediaUrl, {
        headers: {
          ...(click2ApiKey ? { apikey: click2ApiKey } : {}),
          ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
        },
        signal: AbortSignal.timeout(15000),
      });
      if (!mediaResponse.ok) {
        await mediaResponse.text();
        return respond({ success: false, error: `MEDIA_DOWNLOAD_${mediaResponse.status}` }, 502);
      }
      const mime = (mediaResponse.headers.get("content-type") || "image/jpeg").split(";")[0].trim().toLowerCase();
      if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime)) {
        return respond({ success: false, error: "UNSUPPORTED_IMAGE_TYPE" }, 415);
      }
      const bytes = new Uint8Array(await mediaResponse.arrayBuffer());
      if (bytes.byteLength === 0) return respond({ success: false, error: "EMPTY_IMAGE" }, 422);
      if (bytes.byteLength > MAX_IMAGE_BYTES) return respond({ success: false, error: "IMAGE_TOO_LARGE" }, 413);
      const interpretation = await callInterpreter({
        apiKey,
        imageDataUrl: `data:${mime};base64,${bytesToBase64(bytes)}`,
      });
      return respond({ success: true, interpretation });
    }

    const interpretation = await callInterpreter({ apiKey, text: sourceText });
    return respond({ success: true, interpretation });
  } catch (error) {
    const code = error instanceof Error ? error.message : "INTERPRETATION_FAILED";
    return respond({ success: false, error: code.slice(0, 160) }, 502);
  }
});
