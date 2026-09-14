# WA-7 isolated staging certification marker

Preview-only marker for the 2026-09-14 WhatsApp WA-7 certification environment. This branch and its Supabase preview must not be merged into production as part of certification. Feature flags remain fail-closed and production customer data/numbers are excluded.

Recertification boundary: Gates B/C preserve the single accepted immutable raw provider evidence row instead of attempting destructive cleanup through restricted lineage. Exact-head certification must rerun after this marker.
