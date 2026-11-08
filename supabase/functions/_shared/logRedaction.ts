/**
 * Privacy-safe log helpers. Customer phone numbers, personal names and raw provider payloads must never
 * reach function logs in clear text (BUY-086 / F-PII-01).
 */

/** Keeps only the last four digits: +919876543210 -> ********3210. Anything unparsable becomes "****". */
export function maskPhoneForLogs(phone: unknown): string {
  const digits = String(phone ?? "").replace(/\D/g, "");
  if (digits.length <= 4) return "****";
  return `${"*".repeat(digits.length - 4)}${digits.slice(-4)}`;
}

/** Initials only ("Ravi Kumar" -> "R. K."); empty / non-string -> "unknown". */
export function maskNameForLogs(name: unknown): string {
  if (typeof name !== "string") return "unknown";
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "unknown";
  return parts.map((p) => `${Array.from(p)[0].toUpperCase()}.`).join(" ");
}

/** Summarises a provider status batch without recipient identifiers: only a count and allowlisted status kinds. */
const ALLOWED_STATUS_KINDS = new Set(["sent", "accepted", "delivered", "read", "failed", "undelivered"]);
export function summariseStatusBatchForLogs(statuses: unknown): string {
  if (!Array.isArray(statuses)) return "statuses=0";
  const kinds = new Set<string>();
  for (const s of statuses) {
    const kind = typeof s === "object" && s !== null ? (s as { status?: unknown }).status : undefined;
    const normalized = typeof kind === "string" ? kind.trim().toLowerCase() : "";
    kinds.add(ALLOWED_STATUS_KINDS.has(normalized) ? normalized : "unknown");
  }
  return `statuses=${statuses.length} kinds=${[...kinds].sort().join(",") || "n/a"}`;
}

/** Order drafts contain customer and commercial data: log identifiers only. */
export function summariseDraftForLogs(draft: unknown): string {
  const id = typeof draft === "object" && draft !== null ? (draft as { id?: unknown }).id : undefined;
  return typeof id === "string" ? `draft_id=${id}` : "draft_id=none";
}
