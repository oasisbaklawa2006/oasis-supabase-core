from pathlib import Path

path = Path('supabase/functions/whatsapp-webhook/index.ts')
text = path.read_text()

text = text.replace(
    'import { safeWebhookHeaders, verifyChallengeToken, verifyMetaSignature } from "../_shared/whatsappWebhookSecurity.ts";\n',
    'import { safeWebhookHeaders, verifyChallengeToken } from "../_shared/whatsappWebhookSecurity.ts";\nimport { authenticateAndParseWebhook } from "../_shared/whatsappWebhookBoundary.ts";\n',
)

start_marker = '  const url = new URL(req.url);\n  const rawBody = new Uint8Array(await req.arrayBuffer());\n'
end_marker = '  const supabaseAdmin = createClient(\n'
start = text.index(start_marker, text.index('serve(async (req) => {'))
end = text.index(end_marker, start)
replacement = '''  const rawBody = new Uint8Array(await req.arrayBuffer());\n  const boundary = await authenticateAndParseWebhook({\n    rawBody,\n    requestUrl: req.url,\n    signatureHeader: req.headers.get("x-hub-signature-256"),\n    verifyToken: Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN"),\n    appSecret: Deno.env.get("WHATSAPP_META_APP_SECRET") || Deno.env.get("WHATSAPP_APP_SECRET"),\n  });\n\n  if (!boundary.ok) {\n    return new Response(JSON.stringify({ error: boundary.code }), {\n      status: boundary.status,\n      headers: safeWebhookHeaders(),\n    });\n  }\n\n  const payload = boundary.payload;\n  if (boundary.statusEvent) {\n    console.log(\n      `[WA_STATUS] status=${boundary.statusEvent.status} message_id=${boundary.statusEvent.providerMessageId ? "present" : "absent"}`,\n    );\n    return new Response(\n      JSON.stringify({ ok: true, event: "status", status: boundary.statusEvent.status }),\n      { status: 200, headers: safeWebhookHeaders() },\n    );\n  }\n\n'''
text = text[:start] + replacement + text[end:]
path.write_text(text)
