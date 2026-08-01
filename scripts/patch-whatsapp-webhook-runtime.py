from pathlib import Path

path = Path('supabase/functions/whatsapp-webhook/index.ts')
text = path.read_text()

text = text.replace(
    'import { fanOutToStudioInbox } from "../_shared/studioInboxFanOut.ts";\n',
    'import { fanOutToStudioInbox } from "../_shared/studioInboxFanOut.ts";\nimport { safeWebhookHeaders, verifyChallengeToken, verifyMetaSignature } from "../_shared/whatsappWebhookSecurity.ts";\n',
)

old_cors = '''const corsHeaders = {\n  "Access-Control-Allow-Origin": "*",\n  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",\n  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",\n};'''
if old_cors not in text:
    raise SystemExit('cors block not found')
text = text.replace(old_cors, 'const corsHeaders = safeWebhookHeaders();')

old_fallback = '''  return {\n    senderPhone: payload?.from || payload?.sender || payload?.mobile || payload?.data?.from || payload?.contact?.wa_id || payload?.waId || "",\n    messageBody: payload?.message || payload?.body || payload?.data?.body || payload?.text?.body || payload?.text || "",\n    messageType: payload?.messageType || payload?.type || payload?.data?.type || "text",'''
new_fallback = '''  const fallbackMessage = payload?.body || payload?.data?.body || payload?.text?.body || payload?.text || "";\n  return {\n    senderPhone: payload?.from || payload?.sender || payload?.mobile || payload?.data?.from || payload?.contact?.wa_id || payload?.waId || "",\n    messageBody: typeof fallbackMessage === "string" ? fallbackMessage : "",\n    messageType: payload?.messageType || payload?.type || payload?.data?.type || "text",'''
if old_fallback not in text:
    raise SystemExit('fallback payload block not found')
text = text.replace(old_fallback, new_fallback)

start = text.index('serve(async (req) => {')
marker = '    const last10 = normalizePhone(senderPhone);'
mid = text.index(marker, start)
new_prefix = '''serve(async (req) => {\n  if (req.method === "GET") {\n    const url = new URL(req.url);\n    const challengeParamNames = ["challange", "challenge", "hub.challenge", "hub_challenge"];\n    const tokenParamNames = ["echo", "hub.verify_token", "verify_token", "token"];\n    const challengeEntry = Array.from(url.searchParams.entries()).find(([key]) =>\n      challengeParamNames.includes(key.toLowerCase())\n    );\n    if (challengeEntry) {\n      const tokenEntry = Array.from(url.searchParams.entries()).find(([key]) =>\n        tokenParamNames.includes(key.toLowerCase())\n      );\n      const verification = verifyChallengeToken(\n        tokenEntry?.[1] ?? null,\n        Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN"),\n      );\n      if (!verification.ok) {\n        return new Response(JSON.stringify({ error: verification.code }), {\n          status: verification.status,\n          headers: safeWebhookHeaders(),\n        });\n      }\n      return new Response(challengeEntry[1], {\n        status: 200,\n        headers: safeWebhookHeaders("text/plain; charset=utf-8"),\n      });\n    }\n    return new Response("Oasis OS Webhook Active", {\n      status: 200,\n      headers: safeWebhookHeaders("text/plain; charset=utf-8"),\n    });\n  }\n\n  if (req.method === "OPTIONS") {\n    return new Response(null, { status: 204, headers: safeWebhookHeaders() });\n  }\n\n  if (req.method !== "POST") {\n    return new Response(JSON.stringify({ error: "method_not_allowed" }), {\n      status: 405,\n      headers: safeWebhookHeaders(),\n    });\n  }\n\n  const url = new URL(req.url);\n  const rawBody = new Uint8Array(await req.arrayBuffer());\n  const source = url.searchParams.get("source");\n  let authResult;\n  if (source === "click2api") {\n    authResult = verifyChallengeToken(\n      url.searchParams.get("token"),\n      Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN"),\n    );\n  } else {\n    authResult = await verifyMetaSignature(\n      rawBody,\n      req.headers.get("x-hub-signature-256"),\n      Deno.env.get("WHATSAPP_META_APP_SECRET") || Deno.env.get("WHATSAPP_APP_SECRET"),\n    );\n  }\n\n  if (!authResult.ok) {\n    return new Response(JSON.stringify({ error: authResult.code }), {\n      status: authResult.status,\n      headers: safeWebhookHeaders(),\n    });\n  }\n\n  let payload: any;\n  try {\n    payload = JSON.parse(new TextDecoder().decode(rawBody));\n  } catch {\n    return new Response(JSON.stringify({ error: "invalid_json" }), {\n      status: 400,\n      headers: safeWebhookHeaders(),\n    });\n  }\n\n  const nestedStatus = payload?.entry?.[0]?.changes?.[0]?.value?.statuses?.[0];\n  const click2apiStatus = typeof payload?.message?.message_status === "string"\n    ? payload.message.message_status\n    : null;\n  if (nestedStatus || click2apiStatus) {\n    const status = nestedStatus?.status || click2apiStatus || "unknown";\n    const providerMessageId = nestedStatus?.id || payload?.response?.messages?.[0]?.id || null;\n    console.log(`[WA_STATUS] status=${status} message_id=${providerMessageId ? "present" : "absent"}`);\n    return new Response(JSON.stringify({ ok: true, event: "status", status }), {\n      status: 200,\n      headers: safeWebhookHeaders(),\n    });\n  }\n\n  const supabaseAdmin = createClient(\n    Deno.env.get("SUPABASE_URL")!,\n    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!\n  );\n\n  try {\n    const waAutoOrderWritesEnabled = isWaWebhookAutoOrderWritesEnabled((k) => Deno.env.get(k));\n    const waOwnerReassignmentEnabled = isWaWebhookOwnerReassignmentEnabled((k) => Deno.env.get(k));\n\n    const { senderPhone, messageBody, messageType, mediaUrl, mediaMime, messageId, profileName, timestampSec } =\n      extractPayloadFields(payload);\n\n'''
text = text[:start] + new_prefix + text[mid:]

text = text.replace('{ ...corsHeaders, "Content-Type": "application/json" }', 'safeWebhookHeaders()')

path.write_text(text)
print('patched whatsapp-webhook/index.ts')
