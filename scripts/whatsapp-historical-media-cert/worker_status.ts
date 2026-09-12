export const ALLOWED_WORKER_STATUSES = new Set([
  "OK",
  "HIST_MEDIA_TOO_LARGE",
  "HIST_MEDIA_UPLOAD_FAILED",
  "HIST_MEDIA_BUCKET_LOOKUP_FAILED",
  "HIST_MEDIA_BUCKET_CREATE_FAILED",
  "HIST_CONTACT_SEED_FAILED",
  "HIST_PACKET_SEED_FAILED",
  "HIST_MESSAGE_SEED_FAILED",
  "UNPAIRED_CASE",
  "WORKER_DIRECT_INVOKE_FAILED",
  "WORKER_NOT_CONFIGURED",
  "MEDIA_TOO_LARGE",
  "MEDIA_URL_INVALID",
  "MEDIA_URL_PROTOCOL_NOT_ALLOWED",
  "MEDIA_HOST_NOT_ALLOWED",
  "MEDIA_DOWNLOAD_FAILED",
  "PROVIDER_LIMITATION",
  "HARNESS_DEFECT",
  "MEDIA_QUALITY_LIMITATION",
]);

export function classifyWorkerStatus(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const code = raw.split(":")[0]?.trim();
  if (code && ALLOWED_WORKER_STATUSES.has(code)) return code;
  if (raw.includes("GEMINI") || raw.includes("WORKER")) return "PROVIDER_LIMITATION";
  if (raw.includes("TOO_LARGE")) return "MEDIA_QUALITY_LIMITATION";
  if (raw.includes("HIST_")) return "HARNESS_DEFECT";
  return "HARNESS_DEFECT";
}

export function sanitizeWorkerStatus(status: string): string {
  const code = status.split(":")[0]?.trim() ?? "HARNESS_DEFECT";
  return ALLOWED_WORKER_STATUSES.has(code) ? code : "HARNESS_DEFECT";
}
