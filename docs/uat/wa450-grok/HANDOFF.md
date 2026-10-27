# Grok direct GitHub handoff — WA450

**Workspace root:** `docs/uat/wa450-grok/` on branch `handoff/wa450-grok-live-uat-20261027`.

1. Read root `AGENTS.md` of the Core repository first, then this folder's `AGENTS.md`.
2. Read `GROK_START_PROMPT.md`, `README.md`, `ACCESS_INTAKE.md`, `QA_GATES.md`, `ROLE_CARDS.md`, and `TEST_MATRIX.csv`.
3. Confirm `SUPABASE_RUNTIME_ATTESTATION.md`. The predeploy baseline was v173, deployed version is v174. Verify against live read-only Supabase if your own connector becomes available.
4. Treat this as a **documentation-only isolated handoff branch**; do not merge the kit into protected `main`. This branch does not grant permissions to write production, send WhatsApp or perform MFA.
5. Start OBSERVE mode and ask the owner for only the next missing non-secret item. Give no secrets to chat or GitHub.
6. Private run ledgers belong in `evidence/runs/` and must never be pushed into source control.
7. Python tools `uat_ledger.py` and `actor_sessions.py` are provided in this same directory. Run the standard-library-only recorder locally; save private run evidence under ignored `evidence/runs/`.
8. Do not invent real staff, provider receipts or signed callback evidence. Issue #450 remains open until human signoff.

**Canonical owner issue:** https://github.com/oasisbaklawa2006/oasis-supabase-core/issues/450
