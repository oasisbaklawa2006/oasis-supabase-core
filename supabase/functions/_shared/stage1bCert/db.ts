/** @file Stage-1B persistence helpers via preview service-role client. */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import type { Fixture, PersistedOutcome } from "./constants.ts";
import { fanOutToStudioInbox } from "../studioInboxFanOut.ts";

export function runPhone(runTag: string, index: number): string {
  const seed = Number.parseInt(runTag.slice(0, 6), 16) % 900000000;
  const local = 7000000000 + ((seed * 100 + index) % 2999999999);
  return `91${String(local).slice(-10)}`;
}

function ingressCommercialEligible(fixture: Fixture): boolean {
  const intent = String(fixture.ground_truth.intent ?? "");
  if (["NEW_ORDER", "AMENDMENT", "CANCELLATION"].includes(intent)) return true;
  if (fixture.ground_truth.expect_clarification === true) return true;
  if (fixture.ground_truth.must_fail_closed === true) return true;
  return false;
}

export async function assertNoOutstandingBacklog(
  admin: SupabaseClient,
): Promise<{ cert_backlog: number; non_cert_backlog: number }> {
  const { data: jobs, error } = await admin
    .from("whatsapp_packet_ai_dispatch_jobs")
    .select("id, state, packet_id")
    .in("state", ["QUEUED", "RETRY", "BLOCKED_KNOWLEDGE_AUTHORITY", "LEASED"]);
  if (error) throw new Error(`BACKLOG_QUERY_FAILED:${error.message}`);

  if (!jobs?.length) return { cert_backlog: 0, non_cert_backlog: 0 };

  const packetIds = jobs.map((j) => j.packet_id).filter(Boolean);
  const { data: messages } = await admin
    .from("whatsapp_messages")
    .select("provider_message_id, packet_id")
    .in("packet_id", packetIds);

  const certPacketIds = new Set<string>();
  const nonCertPacketIds = new Set<string>();
  for (const packetId of packetIds) {
    const ids = (messages ?? [])
      .filter((m) => m.packet_id === packetId)
      .map((m) => m.provider_message_id ?? "");
    const certOwned = ids.length > 0 &&
      ids.every((id) => id.startsWith("cert-") || id.startsWith("wa-s1b-"));
    if (certOwned) certPacketIds.add(packetId);
    else nonCertPacketIds.add(packetId);
  }

  if (nonCertPacketIds.size) {
    throw new Error(`PREEXISTING_NONCERT_DISPATCH_BACKLOG:${nonCertPacketIds.size}`);
  }
  return { cert_backlog: certPacketIds.size, non_cert_backlog: 0 };
}

export async function reconcilePriorRetryJobs(
  admin: SupabaseClient,
): Promise<number> {
  const { data: retryJobs } = await admin
    .from("whatsapp_packet_ai_dispatch_jobs")
    .select("id, packet_id, state")
    .eq("state", "RETRY");

  let reconciled = 0;
  for (const job of retryJobs ?? []) {
    const { data: messages } = await admin
      .from("whatsapp_messages")
      .select("provider_message_id")
      .eq("packet_id", job.packet_id);
    const ids = (messages ?? []).map((m) => m.provider_message_id ?? "");
    const certOwned = ids.length > 0 &&
      ids.every((id) => id.startsWith("cert-") || id.startsWith("wa-s1b-"));
    if (!certOwned) continue;
    reconciled += 1;
  }
  return reconciled;
}

export async function seedPacket(
  admin: SupabaseClient,
  fixture: Fixture,
  index: number,
  mediaUrls: string[],
  runId: string,
  runTag: string,
): Promise<{ packetId: string; providerIds: string[] }> {
  const contactId = crypto.randomUUID();
  const packetId = crypto.randomUUID();
  const phone = runPhone(runTag, index);
  const providerIds = mediaUrls.map((_, i) => `wa-s1b-${runTag}-${fixture.id}-${i}`);
  const orderLikeHint = ingressCommercialEligible(fixture);

  const { error: contactErr } = await admin.from("whatsapp_contacts").insert({
    id: contactId,
    phone_number: phone,
    customer_name: `S1B ${fixture.id}`,
  });
  if (contactErr) throw new Error(`CONTACT_SEED_FAILED:${contactErr.message}`);

  const fragmentCount = mediaUrls.length + (fixture.follow_up_text ? 1 : 0);
  const { error: packetErr } = await admin.from("whatsapp_message_packets").insert({
    id: packetId,
    contact_id: contactId,
    stitched_content: {},
    fragment_count: fragmentCount,
    first_message_at: new Date().toISOString(),
    last_message_at: new Date().toISOString(),
    status: "open",
  });
  if (packetErr) throw new Error(`PACKET_SEED_FAILED:${packetErr.message}`);

  for (let i = 0; i < mediaUrls.length; i++) {
    const providerId = providerIds[i];
    const caption = i === 0 ? fixture.caption ?? "" : "";
    await fanOutToStudioInbox({
      supabaseAdmin: admin,
      providerMessageId: providerId,
      senderPhone: phone,
      senderName: `S1B ${fixture.id}`,
      messageBody: caption,
      messageType: fixture.media_type,
      mediaCount: 1,
      conversationKey: `stage1b:${runTag}:${fixture.id}`,
      correctionOfProviderMessageId: null,
      rawPayload: {
        media_url: mediaUrls[i],
        cert: "stage1b",
        cert_run_id: runId,
      },
      timestampSec: Math.floor(Date.now() / 1000) + i,
      orderLikeHint,
      commercialRiskReason: orderLikeHint ? "CERT_STAGE1B_MEDIA_POTENTIAL" : null,
    });

    const { error: msgErr } = await admin.from("whatsapp_messages").insert({
      id: crypto.randomUUID(),
      contact_id: contactId,
      packet_id: packetId,
      direction: "inbound",
      message_type: fixture.media_type,
      content: caption,
      provider: "cert-stage1b",
      provider_message_id: providerId,
      media_url: mediaUrls[i],
      status: "received",
      packet_sequence: i + 1,
      message_timestamp: new Date().toISOString(),
    });
    if (msgErr) throw new Error(`MESSAGE_SEED_FAILED:${msgErr.message}`);
  }

  if (fixture.follow_up_text) {
    const followProvider = `wa-s1b-${runTag}-${fixture.id}-follow`;
    await fanOutToStudioInbox({
      supabaseAdmin: admin,
      providerMessageId: followProvider,
      senderPhone: phone,
      senderName: `S1B ${fixture.id}`,
      messageBody: fixture.follow_up_text,
      messageType: "text",
      mediaCount: 0,
      conversationKey: `stage1b:${runTag}:${fixture.id}`,
      correctionOfProviderMessageId: providerIds[0] ?? null,
      rawPayload: { cert: "stage1b", cert_run_id: runId },
      timestampSec: Math.floor(Date.now() / 1000) + mediaUrls.length + 1,
      orderLikeHint: true,
      commercialRiskReason: "CERT_STAGE1B_CORRECTION",
    });

    const { error: followErr } = await admin.from("whatsapp_messages").insert({
      id: crypto.randomUUID(),
      contact_id: contactId,
      packet_id: packetId,
      direction: "inbound",
      message_type: "text",
      content: fixture.follow_up_text,
      provider: "cert-stage1b",
      provider_message_id: followProvider,
      status: "received",
      packet_sequence: mediaUrls.length + 1,
      message_timestamp: new Date().toISOString(),
    });
    if (followErr) throw new Error(`FOLLOWUP_SEED_FAILED:${followErr.message}`);
    providerIds.push(followProvider);
  }

  return { packetId, providerIds };
}

export async function loadPersistedOutcome(
  admin: SupabaseClient,
  packetId: string,
): Promise<PersistedOutcome> {
  const { data: interpretations } = await admin
    .from("whatsapp_packet_ai_interpretations")
    .select("id, interpretation")
    .eq("packet_id", packetId)
    .order("created_at", { ascending: false })
    .limit(1);

  const interpretationId = interpretations?.[0]?.id ?? null;
  const interpretation = (interpretations?.[0]?.interpretation ?? null) as
    | Record<string, unknown>
    | null;

  let autonomy_outcome: string | null = null;
  let governed_facts: Record<string, unknown> | null = null;
  if (interpretationId) {
    const { data: decisions } = await admin
      .from("whatsapp_order_autonomy_decisions")
      .select("autonomy_outcome, governed_facts")
      .eq("packet_id", packetId)
      .eq("interpretation_id", interpretationId)
      .order("evaluated_at", { ascending: false })
      .limit(1);
    autonomy_outcome = decisions?.[0]?.autonomy_outcome ?? null;
    governed_facts = (decisions?.[0]?.governed_facts ?? null) as
      | Record<string, unknown>
      | null;
  }

  const { data: cases } = await admin
    .from("whatsapp_communication_cases")
    .select("id, case_type, status, next_action")
    .eq("packet_id", packetId)
    .order("updated_at", { ascending: false })
    .limit(1);

  const { data: drafts } = await admin
    .from("sales_order_drafts")
    .select("id, status, promoted_order_id")
    .eq("packet_id", packetId)
    .order("created_at", { ascending: false })
    .limit(1);

  return {
    interpretation_id: interpretationId,
    interpretation,
    autonomy_outcome,
    governed_facts,
    case_id: cases?.[0]?.id ?? null,
    case_type: cases?.[0]?.case_type ?? null,
    case_status: cases?.[0]?.status ?? null,
    next_action: cases?.[0]?.next_action ?? null,
    draft_id: drafts?.[0]?.id ?? null,
    draft_status: drafts?.[0]?.status ?? null,
    promoted_order_id: drafts?.[0]?.promoted_order_id ?? null,
  };
}

export async function reconciliation(
  admin: SupabaseClient,
  runTag: string,
  packetIds: string[],
): Promise<Record<string, number>> {
  if (!packetIds.length) {
    return {
      orphan_raw_messages: 0,
      packets_without_case: 0,
      duplicate_drafts: 0,
      duplicate_promoted_orders: 0,
      unaccounted_potential_orders: 0,
    };
  }

  const prefix = `wa-s1b-${runTag}-`;
  const { data: runRaw } = await admin
    .from("whatsapp_inbound_messages")
    .select("provider_message_id")
    .like("provider_message_id", `${prefix}%`);

  const providerIds = (runRaw ?? []).map((r) => r.provider_message_id).filter(Boolean);
  let orphanRaw = 0;
  if (providerIds.length) {
    const { data: linked } = await admin
      .from("whatsapp_messages")
      .select("provider_message_id")
      .in("provider_message_id", providerIds);
    const linkedSet = new Set((linked ?? []).map((r) => r.provider_message_id));
    orphanRaw = providerIds.filter((id) => !linkedSet.has(id)).length;
  }

  let packetsWithoutCase = 0;
  for (const packetId of packetIds) {
    const { count } = await admin
      .from("whatsapp_communication_cases")
      .select("id", { count: "exact", head: true })
      .eq("packet_id", packetId);
    if (!count) packetsWithoutCase += 1;
  }

  let duplicateDrafts = 0;
  let duplicatePromotions = 0;
  for (const packetId of packetIds) {
    const { data: drafts } = await admin
      .from("sales_order_drafts")
      .select("id, promoted_order_id")
      .eq("packet_id", packetId);
    const draftCount = drafts?.length ?? 0;
    if (draftCount > 1) duplicateDrafts += draftCount - 1;
    const promoted = (drafts ?? []).filter((d) => d.promoted_order_id).length;
    if (promoted > 1) duplicatePromotions += promoted - 1;
  }

  const { data: reconRow } = await admin
    .from("whatsapp_potential_order_reconciliation")
    .select("unaccounted_potential_orders")
    .maybeSingle();

  return {
    orphan_raw_messages: orphanRaw,
    packets_without_case: packetsWithoutCase,
    duplicate_drafts: duplicateDrafts,
    duplicate_promoted_orders: duplicatePromotions,
    unaccounted_potential_orders: Number(reconRow?.unaccounted_potential_orders ?? 0),
  };
}
