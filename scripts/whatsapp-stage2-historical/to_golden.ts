import type { GoldenCase } from "../whatsapp-autonomy-eval/types.ts";
import type { CertificationWindow, ParsedHistoricalMessage } from "./types.ts";
import { inferExpectation } from "./expectations.ts";
import { buildEvidenceInterpretation } from "./interpretation_stub.ts";
import { sha256Hex } from "./parse_export.ts";

/** Keep in sync with run.ts STAGE2_STUB_GENERATION for cert entity isolation. */
const STAGE2_STUB_GENERATION = "20260831-v1";

function senderPhone(caseIndex: number, corpusHash: string): string {
  let hash = 0;
  for (const ch of corpusHash) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  const salt = hash % 9000;
  return `91${String(salt).padStart(4, "0")}${String(caseIndex).padStart(4, "0")}00`.slice(0, 12);
}

function buildWindowBody(
  window: CertificationWindow,
  messages: ParsedHistoricalMessage[],
): string {
  const byIndex = new Map(messages.map((m) => [m.index, m]));
  const parts: string[] = [];
  for (const idx of window.message_indices) {
    const message = byIndex.get(idx);
    if (!message) continue;
    const tag = idx === window.focal_index ? "FOCAL" : "CONTEXT";
    parts.push(`[${tag} #${idx} ${message.timestamp_raw}] ${message.sender}: ${message.body}`);
  }
  return parts.join("\n");
}

export async function windowsToGoldenCases(
  windows: CertificationWindow[],
  messages: ParsedHistoricalMessage[],
  corpusHash: string,
): Promise<GoldenCase[]> {
  const cases: GoldenCase[] = [];
  for (const [caseIndex, window] of windows.entries()) {
    const focal = messages.find((m) => m.index === window.focal_index);
    if (!focal) continue;
    const expectation = inferExpectation(focal, messages, window.message_indices);
    const body = buildWindowBody(window, messages);
    const caseHash = (await sha256Hex(`${corpusHash}:${window.window_id}`)).slice(0, 12);
    const providerMessageId = `stage2-${STAGE2_STUB_GENERATION}-${corpusHash.slice(0, 8)}-${caseHash}`;
    cases.push({
      id: window.window_id,
      traffic_class: window.traffic_class,
      input: {
        submitter_phone: senderPhone(caseIndex + 1, corpusHash),
        submitter_name: window.sender,
        provider_message_id: providerMessageId,
        message_body: focal.body,
        message_type: focal.media_type ?? "text",
        interpretation: buildEvidenceInterpretation(
          focal,
          window.expected_class,
          expectation.ground_truth_intent,
          providerMessageId,
          body,
          window.expected_core_outcome,
        ),
      },
      ground_truth: {
        intent: expectation.ground_truth_intent,
        customer: null,
        branch: null,
        sku: null,
        quantity: null,
        uom: null,
        confirmed_so: false,
      },
      expected_core_outcome: window.expected_core_outcome,
      should_auto_action: window.should_auto_action,
      replay_twice: window.expected_class === "ORDER_AMENDMENT" ||
        window.expected_class === "ORDER_CANCELLATION",
    });
  }
  return cases;
}

export async function caseIdHash(caseId: string, corpusHash: string): Promise<string> {
  return (await sha256Hex(`${corpusHash}:${caseId}`)).slice(0, 16);
}
