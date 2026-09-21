import { createClient } from "npm:@supabase/supabase-js@2.95.0";

import {
  buildGenieTextPrompt,
  extractResponsesText,
  genieOrderJsonSchema,
  parseGenieOrderRequest,
  validateGenieOrderLines,
  type GenieOrderParseRequest,
} from "../_shared/genieOrderParse.ts";
import { resolveSupabasePublicKey } from "../_shared/catalogueAiCopy.ts";

const SYSTEM_PROMPT =
  "You extract B2B order lines from untrusted customer input. Never invent products, SKUs, quantities, pack counts, units, prices, substitutions, or commercial terms. Return only explicitly stated positive quantities. Product names must preserve the customer wording because canonical catalogue matching happens downstream. If information is ambiguous or missing, omit that line rather than guessing.";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

async function requireEligibleBuyer(req: Request): Promise<boolean> {
  const authorization = req.headers.get("Authorization");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = resolveSupabasePublicKey((name) => Deno.env.get(name));
  if (!authorization?.startsWith("Bearer ") || !supabaseUrl || !publicKey) return false;

  const client = createClient(supabaseUrl, publicKey, {
    global: { headers: { Authorization: authorization } },
  });
  const token = authorization.slice(7);
  const { data: userData, error: userError } = await client.auth.getUser(token);
  if (userError || !userData.user?.id) return false;

  const { data: companyId, error } = await client.rpc("customer_buyer_eligible_company_id");
  return !error && typeof companyId === "string" && companyId.length > 0;
}

async function transcribeAudio(input: GenieOrderParseRequest, apiKey: string): Promise<string> {
  const raw = Uint8Array.from(atob(input.contentBase64 ?? ""), (c) => c.charCodeAt(0));
  const file = new File(
    [raw],
    input.fileName ?? "buyer-order-audio.m4a",
    { type: input.mimeType ?? "audio/mp4" },
  );
  const form = new FormData();
  form.append("file", file);
  form.append("model", Deno.env.get("OPENAI_TRANSCRIBE_MODEL")?.trim() || "gpt-4o-mini-transcribe");
  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  const body = await response.json().catch(() => null) as { text?: unknown } | null;
  if (!response.ok || typeof body?.text !== "string" || !body.text.trim()) {
    throw new Error("audio transcription failed");
  }
  return body.text.trim();
}

function buildUserContent(input: GenieOrderParseRequest, transcript?: string) {
  const text = input.mode === "audio" ? transcript ?? "" : input.text ?? "";
  const prompt = buildGenieTextPrompt({ text: text || "Extract order lines from the attached file.", locale: input.locale });

  if (input.mode === "text" || input.mode === "audio") {
    return [{ type: "input_text", text: prompt }];
  }

  const mime = input.mimeType ?? (input.mode === "image" ? "image/jpeg" : "application/pdf");
  const dataUrl = `data:${mime};base64,${input.contentBase64}`;
  if (input.mode === "image") {
    return [
      { type: "input_text", text: prompt },
      { type: "input_image", image_url: dataUrl },
    ];
  }

  return [
    { type: "input_text", text: prompt },
    {
      type: "input_file",
      filename: input.fileName ?? "buyer-order-document",
      file_data: dataUrl,
    },
  ];
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);
  if (!(await requireEligibleBuyer(req))) return json({ ok: false, error: "unauthorized" }, 401);

  let input: GenieOrderParseRequest;
  try {
    input = parseGenieOrderRequest(await req.json());
  } catch (error) {
    return json({ ok: false, error: error instanceof Error ? error.message : "invalid request" }, 400);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  const model = Deno.env.get("OPENAI_GENIE_MODEL")?.trim() || Deno.env.get("OPENAI_CATALOGUE_MODEL")?.trim();
  if (!apiKey || !model) return json({ ok: false, error: "AI service is not configured" }, 503);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const transcript = input.mode === "audio" ? await transcribeAudio(input, apiKey) : undefined;
    const provider = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        max_output_tokens: 1600,
        input: [{
          role: "system",
          content: [{ type: "input_text", text: SYSTEM_PROMPT }],
        }, {
          role: "user",
          content: buildUserContent(input, transcript),
        }],
        text: {
          format: {
            type: "json_schema",
            name: "buyer_order_lines",
            strict: true,
            schema: genieOrderJsonSchema,
          },
        },
      }),
    });

    const providerBody = await provider.json().catch(() => null);
    if (!provider.ok) return json({ ok: false, error: "AI provider request failed" }, 502);

    const lines = validateGenieOrderLines(JSON.parse(extractResponsesText(providerBody)));
    return json({
      ok: true,
      lines,
      human_clarification_required: lines.length === 0,
      generated_at: new Date().toISOString(),
    }, 200);
  } catch (error) {
    const message = error instanceof DOMException && error.name === "AbortError"
      ? "AI provider request timed out"
      : error instanceof Error ? error.message : "AI provider response was invalid";
    return json({ ok: false, error: message }, 502);
  } finally {
    clearTimeout(timeout);
  }
});
