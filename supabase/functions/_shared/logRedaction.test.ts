// Dependency-free assertions so the test runs offline and in CI without remote imports.
/** Assert exact JSON-serialized equality for dependency-free Deno tests. */
function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`expected ${JSON.stringify(expected)} but got ${JSON.stringify(actual)}`);
  }
}
/** Reject any regex pattern matching a privacy-filtered string. */
function assertNotMatch(actual: string, pattern: RegExp): void {
  if (pattern.test(actual)) throw new Error(`${JSON.stringify(actual)} must not match ${pattern}`);
}
import {
  maskNameForLogs,
  maskPhoneForLogs,
  summariseDraftForLogs,
  summariseStatusBatchForLogs,
} from "./logRedaction.ts";

Deno.test("phone numbers keep only the last four digits", () => {
  assertEquals(maskPhoneForLogs("+919876543210"), "********3210");
  assertEquals(maskPhoneForLogs("919876543210"), "********3210");
  assertEquals(maskPhoneForLogs("98 7654-3210"), "******3210");
  assertEquals(maskPhoneForLogs("123"), "****");
  assertEquals(maskPhoneForLogs(undefined), "****");
  assertEquals(maskPhoneForLogs(null), "****");
  assertNotMatch(maskPhoneForLogs("+919876543210"), /98765/);
});

Deno.test("names reduce to initials", () => {
  assertEquals(maskNameForLogs("Ravi Kumar"), "R. K.");
  assertEquals(maskNameForLogs("  asha  "), "A.");
  assertEquals(maskNameForLogs(""), "unknown");
  assertEquals(maskNameForLogs(42), "unknown");
});

Deno.test("status batches log counts and kinds only", () => {
  const out = summariseStatusBatchForLogs([
    { id: "wamid.X", status: "delivered", recipient_id: "919876543210" },
    { id: "wamid.Y", status: "read", recipient_id: "919876543211" },
  ]);
  assertEquals(out, "statuses=2 kinds=delivered,read");
  assertNotMatch(out, /9198765|wamid/);
  assertEquals(summariseStatusBatchForLogs("x"), "statuses=0");
  assertEquals(summariseStatusBatchForLogs([{ status: "bad status!" }]), "statuses=1 kinds=unknown");
  assertEquals(summariseStatusBatchForLogs([{ status: "ravi_kumar" }]), "statuses=1 kinds=unknown");
  assertEquals(summariseStatusBatchForLogs([{ status: "SENT" }, { status: "failed" }]), "statuses=2 kinds=failed,sent");
});

Deno.test("drafts log only their id", () => {
  assertEquals(summariseDraftForLogs({ id: "abc", customer_name: "Ravi", phone: "9198" }), "draft_id=abc");
  assertEquals(summariseDraftForLogs(null), "draft_id=none");
});

Deno.test("whatsapp-webhook source no longer logs raw phone numbers, names or payloads", async () => {
  const source = await Deno.readTextFile(new URL("../whatsapp-webhook/index.ts", import.meta.url));
  const lines = source.split("\n").map((l, i) => ({ l, n: i + 1 }));
  const logging = lines.filter(({ l }) => /console\.(log|info|debug|warn|error)\(/.test(l) || /^\s+`.*\$\{/.test(l));
  for (const { l, n } of logging) {
    if (/phone=\$\{phone91\}|\$\{sender\.name \|\| |PI sent to \$\{phone91\}|\$\{sender\.name\}|JSON\.stringify\(payload\.statuses\)|JSON\.stringify\(draftOrder\)/.test(l)) {
      throw new Error(`PII logging regression at index.ts:${n}: ${l.trim()}`);
    }
  }
  // the multi-line [WA-GOV] sales-exec log carries sender.name on the following line
  if (/Sales exec \$\{sender\.name\}/.test(source)) throw new Error("sender.name logged in [WA-GOV] sales exec message");
});


Deno.test("webhook logging redacts commercial identity, document references and upstream exception text", async () => {
  const source = await Deno.readTextFile(new URL("../whatsapp-webhook/index.ts", import.meta.url));
  const forbidden: Array<{ description: string; pattern: RegExp }> = [
    { description: "raw commercial company name", pattern: /Governed identity map[^\n]*\$\{companyName\}/ },
    { description: "raw commercial company id in log", pattern: /(?:Owner reassignment enabled|Sales exec|Pipeline C auto-order skipped|Creating draft order|Direct non-order reply suppressed)[^\n]*\$\{companyId\}/ },
    { description: "sender identity fallback user id", pattern: /Proxy staff sender unresolved:[^\n]*\$\{sender\.name\s*\?\s*maskNameForLogs\(sender\.name\)\s*:\s*sender\.userId\}/ },
    { description: "invoice reference in log", pattern: /Document parsed: Invoice Ref \$\{documentParseResult\.invoiceRef\}/ },
    { description: "PostgREST message in log", pattern: /Draft result:[^\n]*\$\{orderErr\?\.message/ },
    { description: "raw thrown webhook error", pattern: /console\.error\("whatsapp-webhook error:",\s*msg\)/ },
    { description: "raw AI parser error", pattern: /console\.error\("AI parse error:",\s*e\)/ },
    { description: "raw document parser error", pattern: /console\.error\("Document parse error:",\s*e\)/ },
    { description: "raw media exception in log", pattern: /console\.error\("Media download failed:",\s*mediaErr\)/ },
    { description: "raw contact insertion error message", pattern: /console\.warn\("\[whatsapp-webhook\] whatsapp_contacts insert:",\s*created\.error\.message\)/ },
    { description: "raw WhatsApp message insert error object", pattern: /whatsapp_messages insert failed[^;]*?\n\s*insertError,/s },
  ];
  for (const { description, pattern } of forbidden) {
    if (pattern.test(source)) {
      throw new Error("Sensitive webhook logging regression: " + description);
    }
  }
  if (!source.includes('company_resolution=\${companyId ? "resolved" : "unresolved"}')) {
    throw new Error("Governed identity-map log must retain coarse resolution evidence");
  }
});
