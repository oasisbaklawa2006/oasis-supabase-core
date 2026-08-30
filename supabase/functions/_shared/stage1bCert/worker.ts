/** @file Worker probe/invoke and fixture storage — NON-PRODUCTION cert only. */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  BUCKET,
  WORKER_INVOCATION_TIMEOUT_MS,
  WORKER_PROBE_TIMEOUT_MS,
} from "./constants.ts";

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
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<{ configured: boolean; status: number; error: string | null }> {
  let response: Response;
  try {
    response = await fetch(
      `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: "{}",
        signal: AbortSignal.timeout(WORKER_PROBE_TIMEOUT_MS),
      },
    );
  } catch (error) {
    throw new Error(
      `WORKER_PROBE_FAILED:${error instanceof Error ? error.message.slice(0, 120) : "NETWORK_ERROR"}`,
    );
  }

  const text = await response.text();
  let error: string | null = null;
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    error = typeof parsed.error === "string" ? parsed.error : null;
  } catch {
    error = text.slice(0, 120) || null;
  }

  if (response.status === 503 && error === "WORKER_NOT_CONFIGURED") {
    return { configured: false, status: response.status, error };
  }
  if (response.status === 400 && error === "PACKET_ID_REQUIRED") {
    return { configured: true, status: response.status, error };
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error("WORKER_SERVICE_ROLE_AUTH_REJECTED");
  }
  if (response.status === 404) throw new Error("WORKER_NOT_DEPLOYED");
  throw new Error(
    `WORKER_PROBE_UNEXPECTED:${response.status}:${error ?? "NO_ERROR_CODE"}`,
  );
}

export async function invokeClaimedWorker(
  supabaseUrl: string,
  serviceRoleKey: string,
  expectedPacketId: string,
): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await fetch(
      `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ claim_next: true }),
        signal: AbortSignal.timeout(WORKER_INVOCATION_TIMEOUT_MS),
      },
    );
  } catch (error) {
    throw new Error(
      `WORKER_INVOKE_NETWORK_FAILED:${expectedPacketId}:${error instanceof Error ? error.message.slice(0, 120) : "NETWORK_ERROR"}`,
    );
  }

  const text = await response.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text) as Record<string, unknown>;
  } catch {
    data = { raw: text.slice(0, 500) };
  }
  if (!response.ok) {
    throw new Error(
      `WORKER_INVOKE_FAILED:${expectedPacketId}:${response.status}:${JSON.stringify(data).slice(0, 220)}`,
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
  supabaseUrl: string,
  serviceRoleKey: string,
  packetId: string,
): Promise<Record<string, unknown>> {
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ packet_id: packetId }),
      signal: AbortSignal.timeout(WORKER_INVOCATION_TIMEOUT_MS),
    },
  );
  const text = await response.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text) as Record<string, unknown>;
  } catch {
    data = { raw: text.slice(0, 500) };
  }
  if (!response.ok) {
    throw new Error(
      `WORKER_DIRECT_INVOKE_FAILED:${packetId}:${response.status}:${JSON.stringify(data).slice(0, 220)}`,
    );
  }
  return data;
}
