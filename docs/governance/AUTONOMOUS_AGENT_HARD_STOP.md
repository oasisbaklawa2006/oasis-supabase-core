# Autonomous Agent Hard Stop — oasis-supabase-core

This repository permits autonomous agents (including Cursor Cloud Agents) to investigate, edit, test, commit, push, open or update pull requests, and resolve CI findings.

## Prohibited without explicit owner authorization in the active conversation

Agents must **not** perform any of the following unless the repository owner explicitly authorizes that exact action in the **current conversation thread**:

1. Approve pull requests (including via owner-linked integrations).
2. Merge to `main` or any protected default branch.
3. Deploy production Edge Functions, including high-risk functions such as `whatsapp-webhook`.
4. Run production migrations or dispatch `deploy=true` production migration releases.
5. Change production secrets or dotenvx authority on production (`tcxvcatsqqertcnycuop`).
6. Mutate live production database schema, data, or runtime state.

## Required stop condition

When software is ready, agents must stop at **PR-ready / CI-green** and hand off to the owner for:

- exactly one independent human owner review and approval (AI/agent/bot approval never counts),
- ruleset-governed merge under Core Main Protection (`required_approving_review_count=1`),
- environment-gated production deployment,
- live provider certification.

`PR MERGED != STAGE CLEARED` and `MERGED != PRODUCTION DEPLOYED`.

## Incident reference

The 2026-09-15 `#314` incident established that bot merge permission plus insufficient required checks can merge safety-critical code while launch-relevant governance lanes are still failing. This policy exists to prevent recurrence.
