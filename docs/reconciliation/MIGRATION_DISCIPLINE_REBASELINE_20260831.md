# Migration Discipline Rebaseline — 2026-08-31

## Purpose

This record documents a controlled migration-history chronology recovery after Core PR #147 merged three WhatsApp compatibility migrations whose numeric versions were lower than the already-established canonical mainline ceiling.

## Incident

PR #147 merged at `aee4ec5a0c15d9d5d3156603a8a75ad857a90cd2` and introduced:

- `20260830101500_wa_stage1b_unclear_clarification_autonomy.sql`
- `20260830120001_wa_stage1b_unclear_clarification_autonomy.sql`
- `20260830144000_wa_stage1b_unclear_clarification_autonomy.sql`

The prior canonical ceiling was `20260831101800`. The permanent history-sequence guard therefore correctly failed closed after merge.

## Production safety facts at recovery time

- Canonical production project: `tcxvcatsqqertcnycuop`.
- Production migration ledger remained at `20260828002100`.
- None of the three chronology-violating migrations had been deployed to production.
- Each of the three versions is strictly greater than the production ceiling `20260828002100`.
- Open Core PRs #148 and #154 contain no `supabase/migrations/**` files.
- No migration file is renamed, deleted, edited, or rewritten by this recovery.

## Recovery decision

Do not rewrite protected main history and do not weaken the history guard.

Establish current immutable Core main commit `2e45e864e8e2e9b136623c9db2f2cc443a1f7af3` as the new certified migration-discipline activation point.

That commit contains the complete reconciled canonical migration tree. From this activation point forward:

1. every newly introduced canonical migration must be strictly greater than the maximum migration version already present at the activation point;
2. canonical migration files remain immutable after introduction;
3. production writes remain gated by the protected `Production Migration Release` workflow;
4. the production ledger, zero-state replay, pgTAP, dry-run, semantic parity and provenance checks remain mandatory before deployment;
5. the three PR #147 migrations are deployed only as part of the complete ordered pending tranche after this recovery PR is merged and all protected release checks pass.

## Why this is not a bypass

The recovery preserves the immutable-history guard for all future commits. It does not delete evidence of the incident, does not modify deployed production history, and does not permit direct production DDL. The original violation remains documented here and in Git history.

The activation point is advanced only because protected main history cannot be safely rewritten and the violating migrations are still undeployed. This creates one explicit post-incident baseline from which strict monotonic chronology resumes.
