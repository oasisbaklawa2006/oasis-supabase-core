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
  assert(source.includes("send_whatsapp_to && whatsapp_message"));
  assert(source.includes('"NOT_SENT_RELEASE_GATED"'));
  assert(source.includes('"NOT_REQUESTED"'));
  assert(
    source.includes("whatsapp_notification_status: whatsappNotificationStatus"),
  );
  assertEquals(source.includes("whatsapp_notification_status: true"), false);
  const orderInsert = source.indexOf('.from("orders")\\n      .insert({');
  const orderInsertEnd = source.indexOf("})\\n      .select", orderInsert);
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
