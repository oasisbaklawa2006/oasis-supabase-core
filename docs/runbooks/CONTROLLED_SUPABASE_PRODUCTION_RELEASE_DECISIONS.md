# Controlled Release Safety Decisions

- Automatic merge-to-production execution is permitted only through a GitHub environment that requires approval.
- A read-only preflight always runs first and produces a dry-run artifact.
- Production deployment uses a pinned Supabase CLI version.
- Project identity is checked against `tcxvcatsqqertcnycuop` before read and write operations.
- The workflow deploys the exact triggering commit, not a moving branch head.
- Production writes are serialized with a non-cancelling concurrency group.
- Remote-only migration versions are treated as incidents, not automatically repaired.
- The scheduled sentinel converts silent drift into a visible failed check.
