import { assert, assertEquals } from "jsr:@std/assert@1.0.10";

const source = await Deno.readTextFile(
  new URL("./index.ts", import.meta.url),
);

Deno.test("legacy admin draft source retains access control and order creation", () => {
  assert(source.includes("supabaseAdmin.auth.getUser(token)"));
  assert(source.includes('["ADMIN", "SUPER_ADMIN"]'));
  assert(source.includes("const orderStatus"));
  assert(source.includes("order_id: order.id"));
  assert(source.includes("company_id: resolvedCompanyId"));
});

Deno.test("admin-create-draft cannot send to a request-selected WhatsApp recipient", () => {
  assert(!source.includes("/functions/v1/send-whatsapp"));
  assert(!source.includes("fetch(waUrl"));
  assert(
    !source.includes(
      'Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`',
    ),
  );
  assert(!source.includes("console.log(whatsapp_message"));
});

Deno.test("optional notification input is explicitly reported as not sent", () => {
  assert(source.includes("send_whatsapp_to || whatsapp_message"));
  assert(!source.includes("send_whatsapp_to && whatsapp_message"));
  assert(source.includes('"NOT_SENT_RELEASE_GATED"'));
  assert(source.includes('"NOT_REQUESTED"'));
  assert(
    source.includes("whatsapp_notification_status: whatsappNotificationStatus"),
  );
  assertEquals(source.includes("whatsapp_notification_status: true"), false);
  const orderInsert = source.indexOf(
    ".insert({",
    source.indexOf("const orderStatus"),
  );
  const orderInsertEnd = source.indexOf('.select("id")', orderInsert);
  assert(orderInsert >= 0 && orderInsertEnd > orderInsert);
  assert(
    !source.slice(orderInsert, orderInsertEnd).includes(
      "whatsapp_notification_status",
    ),
  );
});

Deno.test("draft creation retains wamid order dedup but does not conflate it with send dedup", () => {
  assert(source.includes('eq("wamid", wamid)'));
  assert(source.includes('deduped: "wamid"'));
  assert(!source.includes("sendViaClick2API"));
});

Deno.test("WAMID lookup failure cannot continue to order creation", () => {
  const lookup = source.indexOf("error: wamidLookupError");
  const guard = source.indexOf("if (wamidLookupError)");
  const failure = source.indexOf('"WAMID_LOOKUP_UNAVAILABLE"');
  const insert = source.indexOf(".insert({", failure);
  assert(lookup >= 0 && guard > lookup && failure > guard);
  assert(insert > failure);
  assert(source.slice(guard, insert).includes("status: 503"));
});

Deno.test("duplicate WAMID response reports that no WhatsApp was sent", () => {
  const start = source.indexOf('deduped: "wamid"');
  const end = source.indexOf("}), { status: 200", start);
  assert(start >= 0 && end > start);
  assert(
    source.slice(start, end).includes(
      "whatsapp_notification_status: send_whatsapp_to || whatsapp_message",
    ),
  );
  assert(source.slice(start, end).includes('"NOT_SENT_RELEASE_GATED"'));
});
