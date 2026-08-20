import { describe, expect, it } from "vitest";
import type { Message } from "../operatorInboxTypes";
import { isHardFailedOperatorReply } from "../operatorInboxUtils";

function outbound(status: string): Message {
  return {
    id: "m1",
    content: "hello",
    message_type: "text",
    direction: "outbound",
    created_at: "2026-08-20T00:00:00Z",
    packet_sequence: 1,
    status,
    provider: "operator_reply",
  };
}

describe("isHardFailedOperatorReply", () => {
  it("treats acceptance_unknown and pending states as non-fatal", () => {
    expect(isHardFailedOperatorReply(outbound("ACCEPTANCE_UNKNOWN"))).toBe(false);
    expect(isHardFailedOperatorReply(outbound("reconciliation_pending"))).toBe(false);
    expect(isHardFailedOperatorReply(outbound("pending"))).toBe(false);
    expect(isHardFailedOperatorReply(outbound("sent"))).toBe(false);
  });

  it("flags only hard failed operator_reply rows", () => {
    expect(isHardFailedOperatorReply(outbound("failed"))).toBe(true);
    expect(isHardFailedOperatorReply(outbound("error"))).toBe(true);
  });
});
