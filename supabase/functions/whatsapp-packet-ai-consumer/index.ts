/** @file Governed scheduler-facing consumer for the durable WhatsApp packet AI outbox. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import {
  processWorkerRequest,
  WorkerRequestError,
} from "../whatsapp-packet-ai-worker/index.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Pragma": "no-cache",
  "X-Content-Type-Options": "nosniff",
};
const DEFAULT_MAX_JOBS = 3;
const MAX_JOBS_PER_TICK = 5;

type AdminClient = SupabaseClient;

type ConsumerAuthority =
  | { ok: true }
  | { ok: false; status: 401 | 403 | 500; error: string };

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

export function boundedMaxJobs(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    return DEFAULT_MAX_JOBS;
  }
  return Math.min(MAX_JOBS_PER_TICK, Math.max(1, value));
}

async function requireConsumerAuthority(
  req: Request,
  admin: AdminClient,
): Promise<ConsumerAuthority> {
  const candidate = req.headers.get("x-oasis-worker-secret")?.trim() ?? "";
  if (!candidate) return { ok: false, status: 401, error: "unauthorized" };

  const { data, error } = await admin.rpc(
    "verify_whatsapp_packet_ai_consumer_secret",
    { _candidate: candidate },
  );
  if (error) {
    console.error(
      "[whatsapp-packet-ai-consumer] authority lookup failed",
      error.message.slice(0, 160),
    );
    return { ok: false, status: 500, error: "authority_unavailable" };
  }
  return data === true
    ? { ok: true }
    : { ok: false, status: 403, error: "forbidden" };
}

export async function consumeAvailableJobs(
  admin: AdminClient,
  maxJobs: number,
): Promise<Record<string, unknown>> {
  let processed = 0;
  let failed = 0;
  const errors: string[] = [];

  for (let index = 0; index < maxJobs; index += 1) {
    try {
      const result = await processWorkerRequest(admin, { claim_next: true });
      if (result.idle === true) {
        return {
          success: failed === 0,
          idle: processed === 0 && failed === 0,
          processed,
          failed,
          errors,
        };
      }
      processed += 1;
    } catch (error) {
      const message = error instanceof WorkerRequestError
        ? String(error.body.error ?? error.message)
        : error instanceof Error
        ? error.message
        : "PACKET_AI_FAILED";
      const code = message.split(":")[0].slice(0, 120);
      failed += 1;
      errors.push(code);

      if (
        code === "WORKER_NOT_CONFIGURED" ||
        code === "KNOWLEDGE_SNAPSHOT_NOT_ACTIVELY_GOVERNED" ||
        code.startsWith("KNOWLEDGE_SNAPSHOT_LOAD_FAILED")
      ) {
        break;
      }
    }
  }

  return {
    success: failed === 0,
    idle: false,
    processed,
    failed,
    errors,
  };
}

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    return respond({ success: false, error: "CONSUMER_NOT_CONFIGURED" }, 503);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const authority = await requireConsumerAuthority(req, admin);
  if (!authority.ok) {
    return respond(
      { success: false, error: authority.error },
      authority.status,
    );
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const maxJobs = boundedMaxJobs(body.max_jobs);
  const result = await consumeAvailableJobs(admin, maxJobs);
  return respond(result, result.success === true ? 200 : 502);
}

if (import.meta.main) {
  serve(async (req) => {
    try {
      return await handleRequest(req);
    } catch (error) {
      const code = error instanceof Error ? error.message : "CONSUMER_FAILED";
      console.error("[whatsapp-packet-ai-consumer]", code.slice(0, 240));
      return respond({ success: false, error: code.slice(0, 240) }, 502);
    }
  });
}
