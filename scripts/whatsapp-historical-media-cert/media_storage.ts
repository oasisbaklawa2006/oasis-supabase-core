import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { extractZipEntryBytes } from "./media_pairing.ts";
import type { MediaModality } from "./types.ts";

export const HIST_MEDIA_BUCKET = "wa-hist-media-cert";

/** Align with whatsapp-packet-ai-worker/index.ts governed fetch ceilings. */
export const HIST_MEDIA_MAX_IMAGE_BYTES = 8 * 1024 * 1024;
export const HIST_MEDIA_MAX_MEDIA_BYTES = 15 * 1024 * 1024;

function maxBytesForModality(modality: MediaModality): number {
  return modality === "IMAGE" ? HIST_MEDIA_MAX_IMAGE_BYTES : HIST_MEDIA_MAX_MEDIA_BYTES;
}

function mimeForEntry(entryName: string, modality: MediaModality): string {
  const lower = entryName.toLowerCase();
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".webp")) return "image/webp";
  if (lower.endsWith(".gif")) return "image/gif";
  if (/\.(jpg|jpeg)$/.test(lower)) return "image/jpeg";
  if (lower.endsWith(".pdf")) return "application/pdf";
  if (lower.endsWith(".mp3")) return "audio/mpeg";
  if (lower.endsWith(".mp4")) return "video/mp4";
  if (lower.endsWith(".opus")) return "audio/ogg";
  return "application/octet-stream";
}

export async function ensureHistMediaBucket(admin: SupabaseClient): Promise<void> {
  const { data: bucket, error } = await admin.storage.getBucket(HIST_MEDIA_BUCKET);
  if (error && !error.message.includes("not found")) {
    throw new Error(`HIST_MEDIA_BUCKET_LOOKUP_FAILED:${error.message}`);
  }
  if (bucket) {
    await admin.storage.updateBucket(HIST_MEDIA_BUCKET, {
      public: false,
      fileSizeLimit: HIST_MEDIA_MAX_MEDIA_BYTES,
    });
    return;
  }
  const { error: createErr } = await admin.storage.createBucket(HIST_MEDIA_BUCKET, {
    public: false,
    fileSizeLimit: HIST_MEDIA_MAX_MEDIA_BYTES,
  });
  if (createErr) {
    throw new Error(`HIST_MEDIA_BUCKET_CREATE_FAILED:${createErr.message}`);
  }
}

export async function uploadHistoricalMedia(
  admin: SupabaseClient,
  supabaseUrl: string,
  runTag: string,
  zipPath: string,
  archiveEntry: string,
  modality: MediaModality,
  caseId: string,
): Promise<string> {
  const bytes = await extractZipEntryBytes(zipPath, archiveEntry);
  const maxBytes = maxBytesForModality(modality);
  if (bytes.byteLength > maxBytes) {
    throw new Error(`HIST_MEDIA_TOO_LARGE:${bytes.byteLength}`);
  }
  const sanitizedEntry = archiveEntry.replace(/[^a-zA-Z0-9._-]+/g, "_");
  const objectPath = `${runTag}/${caseId}/${sanitizedEntry}`;
  const { error } = await admin.storage.from(HIST_MEDIA_BUCKET).upload(
    objectPath,
    bytes,
    { contentType: mimeForEntry(archiveEntry, modality), upsert: true },
  );
  if (error) {
    throw new Error(`HIST_MEDIA_UPLOAD_FAILED:${error.message}`);
  }
  const { data: signed, error: signErr } = await admin.storage
    .from(HIST_MEDIA_BUCKET)
    .createSignedUrl(objectPath, 3600);
  if (signErr || !signed?.signedUrl) {
    throw new Error(`HIST_MEDIA_SIGN_FAILED:${signErr?.message ?? "missing_url"}`);
  }
  return signed.signedUrl;
}

export async function cleanupHistMediaRun(
  admin: SupabaseClient,
  runTag: string,
): Promise<void> {
  const { data: objects, error } = await admin.storage.from(HIST_MEDIA_BUCKET).list(runTag);
  if (error || !objects?.length) return;
  const paths: string[] = [];
  for (const entry of objects) {
    if (entry.id) {
      paths.push(`${runTag}/${entry.name}`);
      continue;
    }
    const { data: nested } = await admin.storage.from(HIST_MEDIA_BUCKET).list(
      `${runTag}/${entry.name}`,
    );
    for (const child of nested ?? []) {
      if (child.name) paths.push(`${runTag}/${entry.name}/${child.name}`);
    }
  }
  if (paths.length) {
    await admin.storage.from(HIST_MEDIA_BUCKET).remove(paths);
  }
}

export function createLocalAdmin(): { admin: SupabaseClient; supabaseUrl: string } {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!supabaseUrl) {
    throw new Error("SUPABASE_URL_REQUIRED_FOR_HIST_MEDIA_CERT");
  }
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!serviceRoleKey) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY_REQUIRED_FOR_HIST_MEDIA_CERT");
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { admin, supabaseUrl };
}
