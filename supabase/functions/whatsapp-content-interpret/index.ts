import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const SUPPORTED_IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
const DEVANAGARI = /[\u0900-\u097F]/u;
const DEFAULT_MEDIA_HOST_SUFFIXES = ["click2api.in"] as const;

type InterpretResponse = {
  normalized_text: string;
  extracted_text: string;
  language: string;
  confidence: number;
  warnings: string[];
  source_kind: "text" | "image";
};

type InboundMessage = {
  content: string | null;
  message_type: string | null;
  media_url: string | null;
};

type LoadedMessage = {
  sourceText: string;
  messageType: string;
  mediaUrl: string;
};

const respond = (body: Record<string, unknown>, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });

const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
};

const clampConfidence = (value: unknown): number => {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(1, n));
};

const safeString = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

const sanitizeWarnings = (value: unknown): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.slice(0, 240))
    .slice(0, 12);
};

const sanitizeResult = (raw: unknown, sourceKind: "text" | "image"): InterpretResponse => {
  const obj = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  return {
    normalized_text: safeString(obj.normalized_text, 6000),
    extracted_text: safeString(obj.extracted_text, 6000),
    language: safeString(obj.language, 80) || "unknown",
    confidence: clampConfidence(obj.confidence),
    warnings: sanitizeWarnings(obj.warnings),
    source_kind: sourceKind,
  };
};

const buildPrompt = (sourceKind: "text" | "image", text = ""): string => {
  if (sourceKind === "image") {
    return "Read this WhatsApp order image as business evidence for Oasis Baklawa. Extract only facts that are explicitly visible. Preserve product names, SKU codes, quantities, units, corrections and Hindi/English wording. Translate or transliterate Hindi into concise English for downstream matching, but never invent a product, quantity, unit, customer, price or delivery promise. If a character or fact is unclear, omit it from normalized_text and add a warning. Return JSON only with: {\"normalized_text\":\"literal order text suitable for product/quantity matching\",\"extracted_text\":\"faithful visible text, preserving the original language where possible\",\"language\":\"detected language(s)\",\"confidence\":\"number from 0 to 1 based only on legibility\",\"warnings\":[]}.";
  }
  return `Normalize this WhatsApp business message for Oasis Baklawa order matching. The source may be Hindi, Hinglish or English. Preserve every explicit product name, SKU, quantity, unit and correction. Translate/transliterate Hindi into concise English, but do not add or infer any product, quantity, unit, customer, price or delivery promise that is not explicitly present. If something is ambiguous, preserve the ambiguity and add a warning. Return JSON only with: {"normalized_text":"literal normalized text suitable for product/quantity matching","extracted_text":"the original text unchanged","language":"detected language(s)","confidence":"number from 0 to 1 based only on clarity","warnings":[]}.

SOURCE TEXT:\n${text.slice(0, 6000)}`;
};

const callInterpreter = async (params: {
  apiKey: string;
  text?: string;
  imageDataUrl?: string;
}): Promise<InterpretResponse> => {
  const sourceKind: "text" | "image" = params.imageDataUrl ? "image" : "text";
  const content: Array<Record<string, unknown>> = [
    { type: "text", text: buildPrompt(sourceKind, params.text ?? "") },
  ];
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
};

const parseProviderMessageId = async (req: Request): Promise<string | null> => {
  try {
    const body = await req.json() as Record<string, unknown>;
    return typeof body.provider_message_id === "string" ? body.provider_message_id.trim() || null : null;
  } catch {
    return null;
  }
};

const createScopedClient = (authorization: string): SupabaseClient | null => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return null;
  return createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
};

const loadInboundMessage = async (
  scoped: SupabaseClient,
  providerMessageId: string,
): Promise<{ message: LoadedMessage | null; error: string | null }> => {
  const { data, error } = await scoped
    .from("whatsapp_messages")
    .select("content, message_type, media_url, direction")
    .eq("provider_message_id", providerMessageId)
    .eq("direction", "inbound")
    .maybeSingle();
  if (error) return { message: null, error: "MESSAGE_LOOKUP_FAILED" };
  if (!data) return { message: null, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" };
  const raw = data as InboundMessage;
  return {
    message: {
      sourceText: typeof raw.content === "string" ? raw.content : "",
      messageType: typeof raw.message_type === "string" ? raw.message_type.toLowerCase() : "text",
      mediaUrl: typeof raw.media_url === "string" ? raw.media_url : "",
    },
    error: null,
  };
};

const configuredMediaHostSuffixes = (): string[] => {
  const configured = (Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS") ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase().replace(/^\.+/, ""))
    .filter(Boolean);
  return [...new Set([...DEFAULT_MEDIA_HOST_SUFFIXES, ...configured])];
};

const parseAllowedMediaUrl = (mediaUrl: string): URL => {
  let parsed: URL;
  try {
    parsed = new URL(mediaUrl);
  } catch {
    throw new Error("MEDIA_URL_INVALID");
  }
  if (parsed.protocol !== "https:") throw new Error("MEDIA_URL_PROTOCOL_NOT_ALLOWED");
  if (parsed.username || parsed.password) throw new Error("MEDIA_URL_CREDENTIALS_NOT_ALLOWED");
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, "");
  const allowed = configuredMediaHostSuffixes().some(
    (suffix) => hostname === suffix || hostname.endsWith(`.${suffix}`),
  );
  if (!allowed) throw new Error("MEDIA_HOST_NOT_ALLOWED");
  return parsed;
};

const isClick2ApiHost = (hostname: string): boolean =>
  hostname === "click2api.in" || hostname.endsWith(".click2api.in");

const downloadImageDataUrl = async (mediaUrl: string): Promise<string> => {
  const parsed = parseAllowedMediaUrl(mediaUrl);
  const providerHeaders: Record<string, string> = {};
  if (isClick2ApiHost(parsed.hostname.toLowerCase())) {
    const click2ApiKey = Deno.env.get("CLICK2API_API_KEY");
    const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
    if (click2ApiKey) providerHeaders.apikey = click2ApiKey;
    if (accessToken) providerHeaders.Authorization = `Bearer ${accessToken}`;
  }
  const mediaResponse = await fetch(parsed.toString(), {
    headers: providerHeaders,
    redirect: "manual",
    signal: AbortSignal.timeout(15_000),
  });
  if (mediaResponse.status >= 300 && mediaResponse.status < 400) {
    throw new Error("MEDIA_REDIRECT_NOT_ALLOWED");
  }
  if (!mediaResponse.ok) {
    await mediaResponse.text();
    throw new Error(`MEDIA_DOWNLOAD_${mediaResponse.status}`);
  }
  const mime = (mediaResponse.headers.get("content-type") || "image/jpeg")
    .split(";")[0]
    .trim()
    .toLowerCase();
  if (!SUPPORTED_IMAGE_MIME.has(mime)) throw new Error("UNSUPPORTED_IMAGE_TYPE");
  const bytes = new Uint8Array(await mediaResponse.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error("EMPTY_IMAGE");
  if (bytes.byteLength > MAX_IMAGE_BYTES) throw new Error("IMAGE_TOO_LARGE");
  return `data:${mime};base64,${bytesToBase64(bytes)}`;
};

const interpretLoadedMessage = async (message: LoadedMessage): Promise<InterpretResponse> => {
  const shouldReadImage = message.messageType === "image" && Boolean(message.mediaUrl);
  const shouldNormalizeHindi = DEVANAGARI.test(message.sourceText);
  if (!shouldReadImage && !shouldNormalizeHindi) {
    return {
      normalized_text: message.sourceText,
      extracted_text: message.sourceText,
      language: "not_required",
      confidence: 1,
      warnings: [],
      source_kind: "text",
    };
  }

  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!apiKey) throw new Error("INTERPRETER_NOT_CONFIGURED");
  if (shouldReadImage) {
    const imageDataUrl = await downloadImageDataUrl(message.mediaUrl);
    return callInterpreter({ apiKey, imageDataUrl });
  }
  return callInterpreter({ apiKey, text: message.sourceText });
};

const statusForInterpretationError = (code: string): number => {
  if (code === "INTERPRETER_NOT_CONFIGURED") return 503;
  if (code === "UNSUPPORTED_IMAGE_TYPE") return 415;
  if (code === "EMPTY_IMAGE") return 422;
  if (code === "IMAGE_TOO_LARGE") return 413;
  if (code.startsWith("MEDIA_URL_") || code === "MEDIA_HOST_NOT_ALLOWED" || code === "MEDIA_REDIRECT_NOT_ALLOWED") return 422;
  return 502;
};

const handleRequest = async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond({ success: false, error: "AUTH_REQUIRED" }, 401);
  const scoped = createScopedClient(authorization);
  if (!scoped) return respond({ success: false, error: "SUPABASE_CONFIG_MISSING" }, 500);

  const { data: authData, error: authError } = await scoped.auth.getUser();
  if (authError || !authData.user) return respond({ success: false, error: "AUTH_INVALID" }, 401);

  const providerMessageId = await parseProviderMessageId(req);
  if (!providerMessageId) return respond({ success: false, error: "PROVIDER_MESSAGE_ID_REQUIRED" }, 400);

  const loaded = await loadInboundMessage(scoped, providerMessageId);
  if (loaded.error === "MESSAGE_LOOKUP_FAILED") return respond({ success: false, error: loaded.error }, 500);
  if (!loaded.message) return respond({ success: false, error: loaded.error ?? "MESSAGE_NOT_FOUND_OR_FORBIDDEN" }, 404);

  try {
    const interpretation = await interpretLoadedMessage(loaded.message);
    return respond({ success: true, interpretation });
  } catch (error) {
    const code = error instanceof Error ? error.message : "INTERPRETATION_FAILED";
    return respond({ success: false, error: code.slice(0, 160) }, statusForInterpretationError(code));
  }
};

serve(handleRequest);
