import { createClient } from "npm:@supabase/supabase-js@2.95.0";

import {
  buildGenieTextPrompt,
  parseGenieOrderRequest,
  validateGenieOrderLines,
  type GenieOrderParseRequest,
} from "../_shared/genieOrderParse.ts";
import { resolveSupabasePublicKey } from "../_shared/catalogueAiCopy.ts";
import {
  buildGeminiRequest,
  callGeminiGenerateContent,
  inlineMediaPart,
  textPart,
  type GeminiPart,
} from "../_shared/geminiProvider.ts";

const SYSTEM_PROMPT =
  "You extract B2B order lines from untrusted customer input. Never invent products, SKUs, quantities, pack counts, units, prices, substitutions, or commercial terms. Return JSON only in the shape {\"lines\":[{\"productName\":string,\"quantity\":number,\"uom\":string}]}. Return only explicitly stated positive quantities. Product names must preserve the customer wording because canonical catalogue matching happens downstream. If information is ambiguous or missing, omit that line rather than guessing.";

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
  if (!authorization?.startsWith("Bearer ") || !supabaseUrl || !publicKey) {
    return false;
  }

  const client = createClient(supabaseUrl, publicKey, {
    global: { headers: { Authorization: authorization } },
  });
  const token = authorization.slice(7);
  const { data: userData, error: userError } = await client.auth.getUser(token);
  if (userError || !userData.user?.id) return false;

  const { data: companyId, error } = await client.rpc(
    "customer_buyer_eligible_company_id",
  );
  return !error && typeof companyId === "string" && companyId.length > 0;
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function buildProviderParts(input: GenieOrderParseRequest): GeminiPart[] {
  const sourceText = input.text ??
    "Extract only explicit order lines from the attached buyer order evidence.";
  const parts: GeminiPart[] = [
    textPart(SYSTEM_PROMPT),
    textPart(buildGenieTextPrompt({ text: sourceText, locale: input.locale })),
  ];

  if (input.mode !== "text") {
    const bytes = decodeBase64(input.contentBase64 ?? "");
    const mimeType = input.mimeType ??
      (input.mode === "audio"
        ? "audio/mp4"
        : input.mode === "image"
        ? "image/jpeg"
        : "application/pdf");
    parts.push(inlineMediaPart(bytes, mimeType));
  }

  return parts;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method not allowed" }, 405);
  }
  if (!(await requireEligibleBuyer(req))) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  let input: GenieOrderParseRequest;
  try {
    input = parseGenieOrderRequest(await req.json());
  } catch (error) {
    return json(
      {
        ok: false,
        error: error instanceof Error ? error.message : "invalid request",
      },
      400,
    );
  }

  const apiKey = Deno.env.get("GEMINI_API_KEY")?.trim();
  if (!apiKey) {
    return json({ ok: false, error: "AI service is not configured" }, 503);
  }

  try {
    const raw = await callGeminiGenerateContent(
      apiKey,
      buildGeminiRequest(buildProviderParts(input)),
    );
    const lines = validateGenieOrderLines(JSON.parse(raw));
    return json(
      {
        ok: true,
        lines,
        human_clarification_required: lines.length === 0,
        generated_at: new Date().toISOString(),
      },
      200,
    );
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "AI provider response was invalid";
    return json({ ok: false, error: message }, 502);
  }
});
