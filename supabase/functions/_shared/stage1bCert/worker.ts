/** @file Worker probe/invoke and fixture storage — NON-PRODUCTION cert only. */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  processWorkerRequest,
  WorkerRequestError,
} from "../../whatsapp-packet-ai-worker/index.ts";
import { BUCKET } from "./constants.ts";
import { assertNoOutstandingBacklog } from "./db.ts";

export type FixtureFileInput = {
  name: string;
  base64: string;
  mime?: string;
};

function mimeForFilename(filename: string): string {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "bin";
  if (ext === "png") return "image/png";
  if (ext === "pdf") return "application/pdf";
  if (ext === "mp3") return "audio/mpeg";
  if (ext === "mp4") return "video/mp4";
  return "application/octet-stream";
}

async function invokeWorkerFunction(
  admin: SupabaseClient,
  body: Record<string, unknown>,
): Promise<{ data: Record<string, unknown>; status: number }> {
  try {
    const data = await processWorkerRequest(admin, body);
    return { data, status: 200 };
  } catch (error) {
    if (error instanceof WorkerRequestError) {
      return { data: error.body, status: error.status };
    }
    throw error;
  }
}

export async function ensurePublicBucket(admin: SupabaseClient): Promise<void> {
  const { data: bucket, error } = await admin.storage.getBucket(BUCKET);
  if (error && !error.message.includes("not found")) {
    throw new Error(`CERT_FIXTURE_BUCKET_LOOKUP_FAILED:${error.message}`);
  }
  if (bucket) {
    if (!bucket.public) throw new Error("CERT_FIXTURE_BUCKET_NOT_PUBLIC");
    return;
  }
  const { error: createErr } = await admin.storage.createBucket(BUCKET, {
    public: true,
    fileSizeLimit: 15 * 1024 * 1024,
    allowedMimeTypes: [
      "image/png",
      "application/pdf",
      "audio/mpeg",
      "video/mp4",
    ],
  });
  if (createErr) {
    throw new Error(`CERT_FIXTURE_BUCKET_CREATE_FAILED:${createErr.message}`);
  }
}

export async function uploadFixtureBytes(
  admin: SupabaseClient,
  supabaseUrl: string,
  runTag: string,
  file: FixtureFileInput,
): Promise<string> {
  const bytes = Uint8Array.from(atob(file.base64), (c) => c.charCodeAt(0));
  const mime = file.mime ?? mimeForFilename(file.name);
  const objectPath = `${runTag}/${file.name}`;
  const { error } = await admin.storage.from(BUCKET).upload(objectPath, bytes, {
    contentType: mime,
    upsert: false,
  });
  if (error) {
    throw new Error(
      `FIXTURE_UPLOAD_FAILED:${file.name}:${error.message}`,
    );
  }
  return `${supabaseUrl.replace(/\/$/, "")}/storage/v1/object/public/${BUCKET}/${objectPath}`;
}

export function runtimeSecretReadiness(): Record<string, boolean> {
  return {
    SUPABASE_SERVICE_ROLE_KEY: Boolean(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")),
    GEMINI_API_KEY: Boolean(Deno.env.get("GEMINI_API_KEY")),
    WA_STAGE1B_CERT_SECRET: Boolean(Deno.env.get("WA_STAGE1B_CERT_SECRET")),
  };
}

export async function probeWorkerRuntime(
  admin: SupabaseClient,
): Promise<{ configured: boolean; status: number; error: string | null }> {
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const { data, error } = await admin.functions.invoke("whatsapp-packet-ai-worker", {
    body: {},
    headers: serviceRoleKey
      ? { Authorization: `Bearer ${serviceRoleKey}` }
      : undefined,
  });

  const payload = (data ?? {}) as Record<string, unknown>;
  let probeError = typeof payload.error === "string" ? payload.error : null;

  if (error && "context" in error) {
    try {
      const response = (error as { context: Response }).context;
      const body = await response.clone().json() as Record<string, unknown>;
      if (typeof body.error === "string") probeError = body.error;
    } catch {
      // fall through to generic handling below
    }
  }

  if (probeError === "WORKER_NOT_CONFIGURED") {
    return { configured: false, status: 503, error: probeError };
  }
  if (probeError === "PACKET_ID_REQUIRED") {
    return { configured: true, status: 400, error: probeError };
  }

  if (error) {
    throw new Error(`WORKER_PROBE_INVOKE_FAILED:${error.message}`);
  }

  throw new Error(
    `WORKER_PROBE_UNEXPECTED:${probeError ?? JSON.stringify(payload).slice(0, 120)}`,
  );
}

export async function invokeClaimedWorker(
  admin: SupabaseClient,
  expectedPacketId: string,
): Promise<Record<string, unknown>> {
  const { data, status } = await invokeWorkerFunction(admin, { claim_next: true });
  if (status >= 400) {
    throw new Error(
      `WORKER_INVOKE_FAILED:${expectedPacketId}:${status}:${JSON.stringify(data).slice(0, 220)}`,
    );
  }
  if (data.idle === true) throw new Error("DISPATCH_JOB_MISSING_AFTER_PACKET_SEED");
  if (data.packet_id !== expectedPacketId) {
    throw new Error(
      `DISPATCH_ORDER_CONTAMINATED:expected=${expectedPacketId}:got=${String(data.packet_id)}`,
    );
  }
  return data;
}

export async function invokeWorkerDirect(
  admin: SupabaseClient,
  packetId: string,
): Promise<Record<string, unknown>> {
  const { data, status } = await invokeWorkerFunction(admin, { packet_id: packetId });
  if (status >= 400) {
    throw new Error(
      `WORKER_DIRECT_INVOKE_FAILED:${packetId}:${status}:${JSON.stringify(data).slice(0, 220)}`,
    );
  }
  return data;
}

/** Drains cert-owned dispatch backlog so claim_next cannot cross-contaminate a new run. */
export async function drainCertOwnedDispatchBacklog(
  admin: SupabaseClient,
  maxAttempts = 40,
): Promise<number> {
  let drained = 0;
  for (let i = 0; i < maxAttempts; i++) {
    const { cert_backlog } = await assertNoOutstandingBacklog(admin);
    if (!cert_backlog) break;

    const { data, status } = await invokeWorkerFunction(admin, { claim_next: true });
    if (status >= 400 && status !== 404) break;
    if (data.idle === true) break;
    drained += 1;
  }
  return drained;
}
