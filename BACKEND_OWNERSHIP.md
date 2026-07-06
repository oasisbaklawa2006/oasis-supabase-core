# Backend Ownership

This repository is the canonical Supabase backend authority for the Oasis ecosystem.

Only this repository may contain deployable Supabase infrastructure:

- supabase/migrations
- supabase/functions
- supabase/config.toml
- SQL schema changes
- RPCs
- RLS policies
- storage policies
- edge functions

Frontend repositories must not deploy Supabase functions or migrations.

## High-Risk Rule

Never deploy the legacy whatsapp-webhook unless an explicit ERP webhook migration plan exists.

The legacy whatsapp-webhook is live ERP infrastructure and must not be touched casually.

Safe current function for controlled work:

- whatsapp-studio-inbox-bridge
