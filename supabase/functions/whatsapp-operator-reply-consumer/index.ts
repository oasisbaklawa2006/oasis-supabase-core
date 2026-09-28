/** @file Governed scheduler-facing consumer for durable WhatsApp operator-reply outbox. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import { consumeAvailableReplies } from "../_shared/whatsappOperatorReplyDispatch.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Pragma": "no-cache",
  "X-Content-Type-Options": "nosniff",
};
const DEFAULT_MAX_REPLIES = 2;
const MAX_REPLIES_PER_TICK = 5;

type AdminClient = SupabaseClient;

type ConsumerAuthority =
  | { ok: true }
  | { ok: false; status: 401 | 403 | 500; error: string };

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

export function boundedMaxReplies(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    return DEFAULT_MAX_REPLIES;
  }
  return Math.min(MAX_REPLIES_PER_TICK, Math.max(1, value));
}

async function requireConsumerAuthority(
  req: Request,
  admin: AdminClient,
): Promise<ConsumerAuthority> {
  const candidate = req.headers.get("x-oasis-worker-secret")?.trim() ?? "";
  if (!candidate) return { ok: false, status: 401, error: "unauthorized" };

  const { data, error } = await admin.rpc(
    "verify_whatsapp_operator_reply_consumer_secret",
    { _candidate: candidate },
  );
  if (error) {
    console.error(
      "[whatsapp-operator-reply-consumer] authority lookup failed",
      error.message.slice(0, 160),
    );
    return { ok: false, status: 500, error: "authority_unavailable" };
  }
  return data === true
    ? { ok: true }
    : { ok: false, status: 403, error: "forbidden" };
}

export async function handleOperatorReplyConsumerRequest(
  req: Request,
  admin: AdminClient,
): Promise<Response> {
  if (req.method !== "POST") {
    return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const authority = await requireConsumerAuthority(req, admin);
  if (!authority.ok) {
    return respond(
      { success: false, error: authority.error },
      authority.status,
    );
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const maxReplies = boundedMaxReplies(body.max_replies);
  const result = await consumeAvailableReplies(
    admin,
    "whatsapp-operator-reply-consumer",
    maxReplies,
  );
  return respond(result, result.success === true ? 200 : 502);
}

async function handleRequest(req: Request): Promise<Response> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return respond({ success: false, error: "CONSUMER_NOT_CONFIGURED" }, 503);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return await handleOperatorReplyConsumerRequest(req, admin);
}

if (import.meta.main) {
  serve(async (req) => {
    try {
      return await handleRequest(req);
    } catch (error) {
      const code = error instanceof Error ? error.message : "CONSUMER_FAILED";
      console.error("[whatsapp-operator-reply-consumer]", code.slice(0, 240));
      return respond({ success: false, error: code.slice(0, 240) }, 502);
    }
  });
}

export { consumeAvailableReplies };
