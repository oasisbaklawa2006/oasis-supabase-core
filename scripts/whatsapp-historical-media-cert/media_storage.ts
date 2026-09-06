import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { extractZipEntryBytes } from "./media_pairing.ts";
import type { MediaModality } from "./types.ts";

export const HIST_MEDIA_BUCKET = "wa-hist-media-cert";

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
      public: true,
      fileSizeLimit: 50 * 1024 * 1024,
    });
    return;
  }
  const { error: createErr } = await admin.storage.createBucket(HIST_MEDIA_BUCKET, {
    public: true,
    fileSizeLimit: 50 * 1024 * 1024,
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
): Promise<string> {
  const bytes = await extractZipEntryBytes(zipPath, archiveEntry);
  const maxBytes = 50 * 1024 * 1024;
  if (bytes.byteLength > maxBytes) {
    throw new Error(`HIST_MEDIA_TOO_LARGE:${bytes.byteLength}`);
  }
  const objectPath = `${runTag}/${archiveEntry.replace(/[^a-zA-Z0-9._-]+/g, "_")}`;
  const { error } = await admin.storage.from(HIST_MEDIA_BUCKET).upload(
    objectPath,
    bytes,
    { contentType: mimeForEntry(archiveEntry, modality), upsert: true },
  );
  if (error) {
    throw new Error(`HIST_MEDIA_UPLOAD_FAILED:${error.message}`);
  }
  const base = supabaseUrl.replace(/\/$/, "");
  return `${base}/storage/v1/object/public/${HIST_MEDIA_BUCKET}/${objectPath}`;
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
