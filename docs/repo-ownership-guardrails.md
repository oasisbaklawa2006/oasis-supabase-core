# Repo Ownership Guardrails

## Why this exists

`oasis-supabase-core` is the canonical Supabase backend authority for the
Oasis ecosystem (see `BACKEND_OWNERSHIP.md`, `FUNCTION_OWNERSHIP.md`). Two
sibling frontend repos — `Oasis-Baklawa-Central` and `oasis-ai-studio` — each
went through an episode of ownership drift (Catalogue Product AI Studio was
briefly built directly inside Central before being decommissioned there; see
`.ai-intent/CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md`). This document
records the resulting three-repo ownership split so this repo does not, in
turn, absorb either frontend's application code, and
`scripts/check-repo-boundaries.sh` enforces it in CI.

## Ownership split

- **oasis-supabase-core** (this repo) owns:
  - Supabase migrations
  - RLS policies
  - Backend schema authority
  - Edge Functions
  - Database DDL
  - Shared backend function code under `supabase/functions/_shared`
  - Creation of the catalogue AI-Studio draft/audit tables
    (`catalogue_ai_studio_drafts`, `catalogue_ai_studio_draft_audit_log`)

- **oasis-ai-studio** owns:
  - Catalogue Product AI Studio frontend
  - Product intelligence frontend
  - Content draft studio
  - Image prompt studio
  - Packaging/variant readiness
  - Export/copy preview
  - The AI-Studio draft workflow UI

- **Oasis-Baklawa-Central** owns:
  - Operations/admin frontend
  - Product master administration
  - Orders, finance, dispatch, warehouse
  - Inventory execution, production execution
  - The approval inbox
  - The buyer catalogue
  - The operational catalogue connector/intake

This repo has no frontend of its own — no `src/`, no page/component tree, no
build tooling (Vite/Next/Tailwind/PostCSS config), and no `package.json`
declaring a frontend framework. Frontend application code belongs in Central
or `oasis-ai-studio`, never here.

### Not scanned: `.ai-intent/` and `docs/`

`.ai-intent/` intentionally documents both frontend repos in detail (routes,
components, screens — see `APP_CENTRAL_INTENT.md`, `APP_AI_STUDIO_INTENT.md`,
`SCREEN_REGISTRY.md`, `CROSS_APPLICATION_BACKLOG_AND_TAKEOVER.md`). Scanning
those files for the same forbidden strings this guardrail blocks in active
code would false-positive on every legitimate mention. `docs/` (including
this file) is excluded for the same reason. Both are documentation, not
deployable implementation — the guardrail only enforces the boundary against
active code paths.

## Mandatory pre-PR ownership gate

Before opening a PR against this repo, run:

```
bash scripts/check-repo-boundaries.sh
```

(There is no `package.json` in this repo, so there is no `npm run` wrapper —
run the script directly.)

A PR that introduces any of the following outside `.ai-intent/`, `docs/`,
`.git/`, `node_modules/`, `dist/`, or `build/` will fail this check and must
not be merged as-is:

- A frontend application path: `src/App.tsx`, `src/main.tsx`,
  `src/pages/**`, `src/components/**`, `app/**`, `pages/**`, `components/**`,
  `public/index.html`, `index.html`, `vite.config.*`, `next.config.*`,
  `tailwind.config.*`, `postcss.config.*`.
- A `package.json` that declares a frontend-framework dependency (`vite`,
  `react`, `react-dom`, `@vitejs/react`, `next`, `lucide-react`, `shadcn`).
- A clear frontend route/component ownership string in active code:
  `BrowserRouter`, `createBrowserRouter`, `Route path`, `AdminLayout`,
  `AdminProducts`, `AdminOrders`, `AdminFinance`, `AdminPackingDispatch`,
  `DispatchManagement`, `InventoryCommandCenter`, `FinanceGovernanceBoard`,
  `Catalogue Product AI Studio`, `Content Draft Studio`, `Media / Hero Image
  Prompt Studio`, `Packaging + Variant`, `Export / Copy Bundle`.

Backend TypeScript under `supabase/functions/**`, and everything under
`supabase/migrations/**` and `supabase/config.toml`, is correct ownership for
this repo and is never flagged. `.github/workflows/repo-boundaries.yml` runs
the same check on every push/PR to `main`.

## If you hit this guardrail

1. Frontend application work belongs in `Oasis-Baklawa-Central` (operations/
   admin) or `oasis-ai-studio` (Catalogue Product AI Studio), not here.
2. If you believe the ownership split itself needs to change, update this
   document and the script's forbidden-pattern list together, deliberately —
   don't just delete the check.
