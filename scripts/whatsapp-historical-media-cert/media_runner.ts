import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { loadPersistedOutcome } from "../../supabase/functions/_shared/stage1bCert/db.ts";
import { invokeWorkerDirect } from "../../supabase/functions/_shared/stage1bCert/worker.ts";
import { seedCertMasterData } from "../../supabase/functions/_shared/stage1bCert/seed.ts";
import type { PairedMediaReference } from "./types.ts";
import { uploadHistoricalMedia } from "./media_storage.ts";

function certPhone(): string {
  const digits: number[] = [];
  while (digits.length < 10) {
    const bytes = crypto.getRandomValues(new Uint8Array(1));
    for (const byte of bytes) {
      if (byte > 249) continue;
      digits.push(byte % 10);
      if (digits.length >= 10) break;
    }
  }
  return `91${digits.join("")}`;
}

function messageTypeFor(modality: string): string {
  if (modality === "IMAGE") return "image";
  if (modality === "PDF") return "document";
  if (modality === "AUDIO") return "audio";
  if (modality === "VIDEO") return "video";
  return "document";
}

function orderLikeHint(ref: PairedMediaReference): boolean {
  const cls = ref.ground_truth.expected_class;
  return ["ORDER", "ORDER_AMENDMENT", "SAMPLE_REQUEST", "CUSTOMISATION"].includes(cls);
}

export async function seedHistoricalMediaPacket(
  admin: SupabaseClient,
  ref: PairedMediaReference,
  mediaUrl: string,
  runTag: string,
  caseIndex: number,
): Promise<{ packetId: string; providerIds: string[] }> {
  const contactId = crypto.randomUUID();
  const packetId = crypto.randomUUID();
  const phone = certPhone();
  const providerIds: string[] = [];
  const sequence: Array<{
    index: number;
    message: typeof ref.focal | typeof ref.context_messages[0];
    isFocal: boolean;
  }> = [];

  const allIndices = ref.window?.message_indices ?? [ref.message_index];
  const byIndex = new Map<number, typeof ref.focal | typeof ref.context_messages[0]>();
  byIndex.set(ref.focal.index, ref.focal);
  for (const message of ref.context_messages) byIndex.set(message.index, message);
  for (const idx of allIndices.sort((a, b) => a - b)) {
    const message = byIndex.get(idx);
    if (!message) continue;
    sequence.push({ index: idx, message, isFocal: idx === ref.message_index });
  }

  const { error: contactErr } = await admin.from("whatsapp_contacts").insert({
    id: contactId,
    phone_number: phone,
    customer_name: `HIST ${ref.case_id}`,
  });
  if (contactErr) throw new Error(`HIST_CONTACT_SEED_FAILED:${contactErr.message}`);

  const { error: packetErr } = await admin.from("whatsapp_message_packets").insert({
    id: packetId,
    contact_id: contactId,
    stitched_content: {},
    fragment_count: sequence.length,
    first_message_at: new Date().toISOString(),
    last_message_at: new Date().toISOString(),
    status: "open",
  });
  if (packetErr) throw new Error(`HIST_PACKET_SEED_FAILED:${packetErr.message}`);

  let seq = 1;
  for (const item of sequence) {
    const providerId = `wa-hist-${runTag}-${ref.case_id}-${item.index}-${seq}`;
    providerIds.push(providerId);
    const isMedia = item.isFocal;
    const { error: msgErr } = await admin.from("whatsapp_messages").insert({
      id: crypto.randomUUID(),
      contact_id: contactId,
      packet_id: packetId,
      direction: "inbound",
      message_type: isMedia ? messageTypeFor(ref.modality) : "text",
      content: item.message.body,
      provider: "cert-hist-media",
      provider_message_id: providerId,
      media_url: isMedia ? mediaUrl : null,
      status: "received",
      packet_sequence: seq,
      message_timestamp: new Date().toISOString(),
    });
    if (msgErr) throw new Error(`HIST_MESSAGE_SEED_FAILED:${msgErr.message}`);
    seq += 1;
  }

  return { packetId, providerIds };
}

export async function executeHistoricalMediaCase(
  admin: SupabaseClient,
  supabaseUrl: string,
  zipPath: string,
  ref: PairedMediaReference,
  runTag: string,
  caseIndex: number,
): Promise<{
  packetId: string;
  worker: Record<string, unknown>;
  persisted: Awaited<ReturnType<typeof loadPersistedOutcome>>;
}> {
  if (!ref.archive_entry) throw new Error(`UNPAIRED_CASE:${ref.case_id}`);
  const mediaUrl = await uploadHistoricalMedia(
    admin,
    supabaseUrl,
    runTag,
    zipPath,
    ref.archive_entry,
    ref.modality,
    ref.case_id,
  );
  const { packetId } = await seedHistoricalMediaPacket(
    admin,
    ref,
    mediaUrl,
    runTag,
    caseIndex,
  );
  const worker = await invokeWorkerDirect(admin, packetId);
  const persisted = await loadPersistedOutcome(admin, packetId);
  return { packetId, worker, persisted };
}

export async function countPacketDraftState(
  admin: SupabaseClient,
  packetId: string,
): Promise<{ draft_count: number; promoted_count: number }> {
  const { data: drafts } = await admin
    .from("sales_order_drafts")
    .select("id, promoted_order_id")
    .eq("packet_id", packetId);
  const rows = drafts ?? [];
  return {
    draft_count: rows.length,
    promoted_count: rows.filter((row) => row.promoted_order_id).length,
  };
}

export async function replayHistoricalMediaCase(
  admin: SupabaseClient,
  packetId: string,
): Promise<Record<string, unknown>> {
  return await invokeWorkerDirect(admin, packetId);
}

export async function prepareHistMediaCertRuntime(
  admin: SupabaseClient,
): Promise<void> {
  await seedCertMasterData(admin);
}

export { orderLikeHint };
