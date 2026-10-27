# Oasis Baklawa — WhatsApp #450 Grok Live UAT Workspace

**Status: UAT infrastructure READY; live scenarios NOT EXECUTED.** 27 October 2026.

## Canonical references
- Core: `oasisbaklawa2006/oasis-supabase-core`, protected `main` squash SHA `01a46bc5f6f0a7087c6db3f620421ceb29dd964b`.
- Protected named Edge release: https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/40453001383 — SUCCESS.
- Production project: `tcxvcatsqqertcnycuop`, webhook `whatsapp-webhook` ACTIVE **v174**; bundle SHA `c3fea9d3f817bea59ba5e69b342c44a44d92f1323d3bad171002e06a8a6b8a9e`.
- Audit authority: https://github.com/oasisbaklawa2006/oasis-supabase-core/issues/450 .
- Code release is not WhatsApp 100% certification. No real provider acceptance proof yet.

## How to use
1. Provide Grok with `GROK_START_PROMPT.md` and this workspace. For Grok Build, work inside this folder so the folder-specific `AGENTS.md` loads; NEVER replace repo-root AGENTS.md.
2. Start in **OBSERVE** mode and read `ACCESS_INTAKE.md`. Grok asks for missing **non-secret** information one at a time. Supply secret permissions through a human-controlled vault/secure connection outside Grok chat, not by paste, export or screenshots of tokens.
3. Run `python3 uat_ledger.py init --run-id WA450-YYYYMMDD-01` and `python3 uat_ledger.py checklist`. Keep a run ID for every session. No privileged actions from ledger tooling.
4. Assign personas using `ROLE_CARDS.md`; simulated subagents generate scenarios and check observations, but **only properly authenticated/authorized human or explicitly provisioned test identities** can act as staff in production. Each actor logs evidence with `python3 uat_ledger.py record --run-id ... --event <json>`.
5. Run the `TEST_MATRIX.csv` cases in order. Begin with safe read-only proof, then consenting provider test traffic only after an explicit case-specific send budget/approval. Do not target real customers or bulk data.
6. Export the result with `python3 uat_ledger.py verify --run-id ...` and `python3 uat_ledger.py report --run-id ...`. Attach redacted evidence summary, hashed IDs, immutable workflow URLs to Core issue #450. A green report is **not** legal permission to close issue #450; final signoff requires real provider, AAL2 and business workflow evidence.

## Two environments, not one shared unrestricted account
- **OFFLINE/SIMULATED:** role-play prompts, static fixture data and negative cases; no network, no provider sends. Always available.
- **LIVE/CONSENTED:** existing protected production v174; dedicated owner-consented recipient(s), authenticated and minimally privileged staff, separate provider sandbox/dashboard if available; allowlisted test traffic ONLY. This workspace does not create users, install secrets, add Supabase branches or mutate live historical records.

## The only expected owner actions
A. Verify consenting UAT phone(s), create/approve test identities and enroll MFA through official app/identity flow. B. Grant narrowly scoped temporary read-only dashboards plus time-bounded test send authority via secure channel. C. Authorize the named test plan, spending cap and test window. D. Review final evidence and sign or deny certification. All other scenario generation, observations, redaction, trace reconciliation and draft reporting can be delegated.

## Minimal installation
Python 3.10+ standard library only for the offline evidence recorder. Optional Grok Build (`grok`) CLI installation/login is performed by the owner or their authorized workstation administrator. `grok -p` can generate role-play test messages, but it cannot be assumed to possess a WhatsApp account, browser connection, provider API access, or staff MFA. Absence of those capabilities is BLOCKED, not PASS.

## Current historical baseline — observational, NOT UAT test results
Outbox 69 ACCEPTED / 70 QUARANTINED; outbound attempts table 0; 134 OPEN department tasks (all unassigned and overdue), 121 older than 7 days; 219 AI dispatch COMPLETED / 1 DEAD_LETTERED; 1 verified MFA factor. These values change; capture a fresh read-only baseline before testing, do not rewrite them.