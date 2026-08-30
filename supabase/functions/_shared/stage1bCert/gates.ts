/** @file Stage-1B gate evaluation (A–E) — NON-PRODUCTION preview cert only. */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import type {
  Fixture,
  FixtureResult,
  GateResult,
  HarnessReport,
} from "./constants.ts";
import { numeric } from "./scoring.ts";
import {
  invokeClaimedWorker,
  invokeWorkerDirect,
} from "./worker.ts";
import {
  loadPersistedOutcome,
  runPhone,
  seedPacket,
} from "./db.ts";
import { fanOutToStudioInbox } from "../studioInboxFanOut.ts";

function failGate(
  gate: GateResult["gate"],
  detail: string,
  metrics?: GateResult["metrics"],
): GateResult {
  return { gate, status: "FAIL", detail, metrics };
}

function passGate(
  gate: GateResult["gate"],
  metrics?: GateResult["metrics"],
): GateResult {
  return { gate, status: "PASS", metrics };
}

/** Gate A: all mandatory multimodal fixtures scored against persisted truth. */
export function evaluateGateA(
  results: FixtureResult[],
  mandatoryCount: number,
  dangerousCount: number,
  leakageCount: number,
): GateResult {
  const scored = results.length;
  const mandatoryFailed = scored < mandatoryCount;
  const anyDangerous = dangerousCount > 0;
  const anyLeakage = leakageCount > 0;
  const unscoredFailures = results.some((r) => {
    const gt = r.ground_truth;
    if (gt.expect_clarification === true) {
      return r.scores.clarification_correct === false;
    }
    if (gt.must_not_be_order === true || gt.must_fail_closed === true) {
      return r.scores.dangerous_false_positive;
    }
    if (gt.sku != null && r.scores.sku_correct === false) return true;
    if (gt.quantity != null && r.scores.quantity_correct === false) return true;
    if (gt.intent != null && r.scores.intent_correct === false) return true;
    return false;
  });

  if (mandatoryFailed || anyDangerous || anyLeakage || unscoredFailures) {
    return failGate("A", "CONTROLLED_FIXTURE_SCORING_FAILED", {
      scored,
      mandatory_count: mandatoryCount,
      dangerous_false_positives: dangerousCount,
      invented_commercial_leakage: leakageCount,
    });
  }
  return passGate("A", { scored, mandatory_count: mandatoryCount });
}

/** Gate B: clarification invariants from fixture outcomes + explicit resume probe. */
export async function evaluateGateB(
  admin: SupabaseClient,
  results: FixtureResult[],
  runId: string,
  runTag: string,
  supabaseUrl: string,
): Promise<GateResult> {
  const clarificationFixtures = results.filter((r) =>
    r.ground_truth.expect_clarification === true
  );
  if (!clarificationFixtures.length) {
    return failGate("B", "NO_CLARIFICATION_FIXTURES_IN_RUN");
  }

  let clarificationCorrect = 0;
  let quantityDefaultViolations = 0;
  let inventedSkuViolations = 0;

  for (const result of clarificationFixtures) {
    if (result.scores.clarification_correct === true) clarificationCorrect += 1;
    const line = result.persisted.governed_facts?.order_lines;
    const firstLine = Array.isArray(line) && line[0] && typeof line[0] === "object"
      ? line[0] as Record<string, unknown>
      : null;
    const qty = numeric(firstLine?.quantity);
    if (result.ground_truth.quantity == null && qty === 1) {
      quantityDefaultViolations += 1;
    }
    const governedSku = typeof firstLine?.sku === "string" ? firstLine.sku : null;
    if (
      result.ground_truth.sku == null && governedSku &&
      result.persisted.autonomy_outcome === "AUTO_ELIGIBLE"
    ) {
      inventedSkuViolations += 1;
    }
    if (result.scores.dangerous_false_positive) {
      return failGate("B", "CLARIFICATION_FIXTURE_DANGEROUS_FALSE_POSITIVE", {
        fixture_id: result.fixture_id,
      });
    }
  }

  const probePacketId = crypto.randomUUID();
  const contactId = crypto.randomUUID();
  const phone = runPhone(runTag, 900);
  const providerId = `wa-s1b-${runTag}-gateb-clarify-probe`;
  const probeMediaUrl =
    `${supabaseUrl.replace(/\/$/, "")}/storage/v1/object/public/wa-stage1b-cert/${runTag}/05-quantity-only.png`;

  await admin.from("whatsapp_contacts").insert({
    id: contactId,
    phone_number: phone,
    customer_name: "S1B GateB Clarify Probe",
  });
  await admin.from("whatsapp_message_packets").insert({
    id: probePacketId,
    contact_id: contactId,
    stitched_content: {},
    fragment_count: 1,
    first_message_at: new Date().toISOString(),
    last_message_at: new Date().toISOString(),
    status: "open",
  });

  await fanOutToStudioInbox({
    supabaseAdmin: admin,
    providerMessageId: providerId,
    senderPhone: phone,
    senderName: "S1B GateB",
    messageBody: "Quantity: 12 boxes",
    messageType: "image",
    mediaCount: 1,
    conversationKey: `stage1b:${runTag}:gateb-probe`,
    correctionOfProviderMessageId: null,
    rawPayload: { cert: "stage1b", cert_run_id: runId, gate: "B" },
    timestampSec: Math.floor(Date.now() / 1000),
    orderLikeHint: true,
    commercialRiskReason: "CERT_STAGE1B_GATE_B",
  });

  await admin.from("whatsapp_messages").insert({
    id: crypto.randomUUID(),
    contact_id: contactId,
    packet_id: probePacketId,
    direction: "inbound",
    message_type: "image",
    content: "Quantity: 12 boxes",
    provider: "cert-stage1b",
    provider_message_id: providerId,
    media_url: probeMediaUrl,
    status: "received",
    packet_sequence: 1,
    message_timestamp: new Date().toISOString(),
  });

  await invokeClaimedWorker(admin, probePacketId);
  const persisted = await loadPersistedOutcome(admin, probePacketId);

  const clarificationCreated = persisted.autonomy_outcome === "CLARIFICATION_REQUIRED" ||
    persisted.interpretation?.conclusion?.reply_clearance === "CLARIFICATION_REQUIRED" ||
    persisted.next_action?.includes("CLARIFICATION") === true;

  const { count: draftCount } = await admin
    .from("sales_order_drafts")
    .select("id", { count: "exact", head: true })
    .eq("packet_id", probePacketId);

  await admin
    .from("whatsapp_inbound_messages")
    .delete()
    .eq("provider_message_id", providerId);

  if (
    quantityDefaultViolations > 0 ||
    inventedSkuViolations > 0 ||
    clarificationCorrect < clarificationFixtures.filter((r) =>
      r.scores.clarification_correct !== null
    ).length ||
    !clarificationCreated ||
    (draftCount ?? 0) > 0
  ) {
    return failGate("B", "CLARIFICATION_INVARIANTS_FAILED", {
      clarification_correct: clarificationCorrect,
      quantity_default_violations: quantityDefaultViolations,
      invented_sku_violations: inventedSkuViolations,
      probe_clarification_created: clarificationCreated,
      probe_drafts: draftCount ?? 0,
    });
  }

  return passGate("B", {
    clarification_fixtures: clarificationFixtures.length,
    clarification_correct: clarificationCorrect,
    probe_clarification_created: clarificationCreated,
  });
}

/** Gate C: adversarial replay, concurrency, and isolation probes. */
export async function evaluateGateC(
  admin: SupabaseClient,
  runId: string,
  runTag: string,
  fixture: Fixture,
  mediaUrl: string,
): Promise<{ gate: GateResult; evidence: Record<string, unknown> }> {
  const replayProvider = `wa-s1b-${runTag}-gatec-replay`;
  const phoneA = runPhone(runTag, 901);
  const phoneB = runPhone(runTag, 902);
  const packetA = crypto.randomUUID();
  const packetB = crypto.randomUUID();
  const contactA = crypto.randomUUID();
  const contactB = crypto.randomUUID();
  let replayAccepted = 0;
  let duplicateDrafts = 0;
  let crossCustomerDrafts = 0;

  for (const [contactId, packetId, phone] of [
    [contactA, packetA, phoneA],
    [contactB, packetB, phoneB],
  ] as const) {
    await admin.from("whatsapp_contacts").insert({
      id: contactId,
      phone_number: phone,
      customer_name: `S1B GateC ${phone}`,
    });
    await admin.from("whatsapp_message_packets").insert({
      id: packetId,
      contact_id: contactId,
      stitched_content: {},
      fragment_count: 1,
      first_message_at: new Date().toISOString(),
      last_message_at: new Date().toISOString(),
      status: "open",
    });
  }

  for (let i = 0; i < 10; i++) {
    try {
      await fanOutToStudioInbox({
        supabaseAdmin: admin,
        providerMessageId: replayProvider,
        senderPhone: phoneA,
        senderName: "S1B GateC Replay",
        messageBody: "12 boxes BAK-PIST-250",
        messageType: fixture.media_type,
        mediaCount: 1,
        conversationKey: `stage1b:${runTag}:gatec-replay`,
        correctionOfProviderMessageId: null,
        rawPayload: { cert: "stage1b", cert_run_id: runId, gate: "C", replay: i },
        timestampSec: Math.floor(Date.now() / 1000) + i,
        orderLikeHint: true,
        commercialRiskReason: "CERT_STAGE1B_GATE_C_REPLAY",
      });
      replayAccepted += 1;
    } catch {
      // duplicate provider replay should fail closed on re-ingest
    }
  }

  const { packetId: isoPacketA } = await seedPacket(
    admin,
    { ...fixture, id: "gatec-isolation-a", follow_up_text: undefined },
    903,
    [mediaUrl],
    runId,
    runTag,
  );
  const { packetId: isoPacketB } = await seedPacket(
    admin,
    { ...fixture, id: "gatec-isolation-b", follow_up_text: undefined },
    904,
    [mediaUrl],
    runId,
    `${runTag}b`,
  );

  await invokeClaimedWorker(admin, isoPacketA);
  await invokeClaimedWorker(admin, isoPacketB);

  const concurrentInvocations = await Promise.allSettled([
    invokeWorkerDirect(admin, isoPacketA),
    invokeWorkerDirect(admin, isoPacketA),
  ]);
  const concurrentOk = concurrentInvocations.filter((r) => r.status === "fulfilled").length;

  for (const packetId of [isoPacketA, isoPacketB]) {
    const { data: drafts } = await admin
      .from("sales_order_drafts")
      .select("id")
      .eq("packet_id", packetId);
    if ((drafts?.length ?? 0) > 1) duplicateDrafts += (drafts?.length ?? 0) - 1;
  }

  const { data: promoted } = await admin
    .from("sales_order_drafts")
    .select("packet_id, promoted_order_id")
    .in("packet_id", [isoPacketA, isoPacketB])
    .not("promoted_order_id", "is", null);

  const promotedOrders = new Set((promoted ?? []).map((d) => d.promoted_order_id));
  if (promotedOrders.size > 2) crossCustomerDrafts += promotedOrders.size - 2;

  await admin
    .from("whatsapp_inbound_messages")
    .delete()
    .eq("provider_message_id", replayProvider);

  const evidence = {
    provider_replay_attempts: 10,
    provider_replay_accepted: replayAccepted,
    concurrent_worker_ok: concurrentOk,
    duplicate_drafts: duplicateDrafts,
    cross_customer_promotion_violations: crossCustomerDrafts,
  };

  if (duplicateDrafts > 0 || crossCustomerDrafts > 0 || replayAccepted !== 1) {
    return {
      gate: failGate("C", "ADVERSARIAL_INVARIANTS_FAILED", evidence),
      evidence,
    };
  }

  return { gate: passGate("C", evidence), evidence };
}

/** Gate D: non-order safety from representative fixtures. */
export function evaluateGateD(results: FixtureResult[]): GateResult {
  const nonOrderIds = new Set([
    "10-catalogue",
    "12-payment-screenshot",
    "13-complaint-photo",
    "20-prompt-injection",
  ]);
  const nonOrder = results.filter((r) => nonOrderIds.has(r.fixture_id));
  if (nonOrder.length < 3) {
    return failGate("D", "NON_ORDER_FIXTURES_MISSING");
  }

  for (const result of nonOrder) {
    if (result.scores.dangerous_false_positive) {
      return failGate("D", "NON_ORDER_CONVERTED_TO_ORDER", {
        fixture_id: result.fixture_id,
      });
    }
    if (!result.persisted.case_id) {
      return failGate("D", "NON_ORDER_MISSING_CASE", {
        fixture_id: result.fixture_id,
      });
    }
    if (result.persisted.promoted_order_id) {
      return failGate("D", "NON_ORDER_PROMOTED", {
        fixture_id: result.fixture_id,
      });
    }
  }

  return passGate("D", { non_order_fixtures: nonOrder.length });
}

/** Gate E: final reconciliation invariants. */
export function evaluateGateE(
  report: HarnessReport,
): GateResult {
  const recon = report.reconciliation ?? {};
  const unaccounted = Number(recon.unaccounted_potential_orders ?? 0);
  const dangerous = report.dangerous_media_false_positives;
  const leakage = report.invented_commercial_leakage;
  const dupDrafts = Number(recon.duplicate_drafts ?? 0);
  const dupSo = Number(recon.duplicate_promoted_orders ?? 0);
  const orphan = Number(recon.orphan_raw_messages ?? 0);
  const silentLoss = report.silent_media_loss;
  const packetsWithoutCase = Number(recon.packets_without_case ?? 0);

  const metrics = {
    unaccounted_potential_orders: unaccounted,
    dangerous_false_positives: dangerous,
    invented_commercial_leakage: leakage,
    duplicate_drafts: dupDrafts,
    duplicate_promoted_orders: dupSo,
    orphan_raw_messages: orphan,
    silent_media_loss: silentLoss,
    packets_without_case: packetsWithoutCase,
  };

  if (
    unaccounted !== 0 ||
    dangerous !== 0 ||
    leakage !== 0 ||
    dupDrafts !== 0 ||
    dupSo !== 0 ||
    orphan !== 0 ||
    silentLoss !== 0 ||
    packetsWithoutCase !== 0
  ) {
    return failGate("E", "FINAL_RECONCILIATION_FAILED", metrics);
  }

  return passGate("E", metrics);
}

export function finalVerdict(gates: GateResult[]): "PASS" | "FAIL" {
  return gates.every((g) => g.status === "PASS") ? "PASS" : "FAIL";
}
