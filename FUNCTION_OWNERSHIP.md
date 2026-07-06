# Function Ownership

## High Risk

### whatsapp-webhook

Owner: Legacy ERP / Central backend path
Risk: HIGH
Rule: Do not deploy unless there is an explicit approved ERP webhook migration plan.

This function is connected to the existing WhatsApp/ERP flow. Accidental deployment may break live WhatsApp ingestion.

---

## Controlled / Allowed

### whatsapp-studio-inbox-bridge

Owner: Oasis Supabase Core
Risk: Medium
Rule: Safe to deploy manually for controlled tests after validation.

This function reads ERP WhatsApp rows and writes normalized records into AI Studio inbound storage.

---

### whatsapp-studio-inbox-webhook

Owner: Oasis Supabase Core
Risk: Low/Medium
Rule: Studio-only safe webhook/test harness. Not the production Meta callback.

---

## Deployment Rule

Default deployment command must specify the function name explicitly.

Approved example:

npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt

Prohibited casual deployment:

npx supabase functions deploy whatsapp-webhook --project-ref tcxvcatsqqertcnycuop
