# Core Main Protection — target ruleset

Repository ruleset **Core Main Protection** (`id=20838928`) governs merges to `main`.

## Target required status checks

Apply every context listed in `.github/rulesets/core-main-protection.required-checks.txt`.

`Core merge governance validation` is an always-on PR workflow that cannot be bypassed by path filters.

## Target pull request review policy

| Setting | Target |
| --- | --- |
| `required_approving_review_count` | **2** (no single-review merge) |
| `require_code_owner_review` | **true** |
| `require_last_push_approval` | **true** |
| `dismiss_stale_reviews_on_push` | **true** |
| `required_review_thread_resolution` | **true** |
| `allowed_merge_methods` | `squash` only |

### Human-only approval

- Do **not** list bot/app identities in ruleset bypass actors.
- Revoke **merge** and **approve** capability from `cursor[bot]` and other autonomous apps at the organization/repository integration level.
- Treat empty-body owner approvals immediately before bot merge as an incident signal; verify via GitHub audit log.

## Production deployment remains separately gated

Production migration apply requires:

- `workflow_dispatch` on **Production Migration Release** with `deploy=true` and explicit `release_sha`, and
- approval on the `supabase-production` GitHub Environment.

No repository change here weakens that gate.

## Owner application steps (manual — not automated by agents)

1. Open GitHub → **Settings → Rules → Rulesets → Core Main Protection**.
2. Add every required status check from `.github/rulesets/core-main-protection.required-checks.txt`.
3. Set **Required approvals** to **2** with code owner review enabled.
4. Remove bot/app bypass entries for merge and review.
5. Verify with:

   ```bash
   bash scripts/check-core-main-protection-ruleset.sh
   ```

6. Confirm `Core merge governance validation` is green on a test PR before merging governance changes.
