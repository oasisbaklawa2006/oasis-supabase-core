# Cursor / AI Credit Economy and Loop-Control Policy

Generated: 2026-07-07
Purpose: Mandatory cost-control, token-control, and anti-loop rules for any AI/dev engine working on the Oasis Baklawa software ecosystem.

This policy exists because uncontrolled AI/Cursor loops can drain money, waste credits, create noisy changes, and make the system less stable. Economy is a functional requirement, not a preference.

---

# 1. Prime Directive

The next AI engine must operate with maximum economy of money, Cursor credits, AI tokens, tool calls, and developer time.

The engine must never enter an endless loop, repeatedly attempt the same failed fix, or allow Cursor/agent mode to keep running without a clear stop condition.

Every action must have:

1. a specific objective,
2. a bounded scope,
3. a known success condition,
4. a rollback/stop condition,
5. the smallest reasonable command/tool usage.

---

# 2. Mandatory Stop-Loss Rules

The AI engine must stop and ask for review when any of these occur:

1. The same command or test fails twice with substantially the same error.
2. The same file is edited twice without resolving the issue.
3. More than two attempted fixes are proposed for the same bug without new evidence.
4. The tool/agent starts making broad unrelated changes.
5. The agent cannot clearly state which file, route, table, or function is responsible.
6. The next step would require scanning or editing a large part of the repo without a targeted reason.
7. The fix would touch production, secrets, RLS, WhatsApp, finance, dispatch, stock, or order promotion.
8. The AI is about to repeat a previous command because it “might work this time.”

When a stop-loss condition is hit, the engine must produce a concise failure note:

- what was attempted,
- exact error/evidence,
- what was ruled out,
- safest next diagnostic,
- whether human approval is needed.

---

# 3. Cursor Usage Controls

Before using Cursor Agent/Composer for any non-trivial change, the AI engine must define:

1. Objective: one sentence.
2. Files allowed to edit: explicit list or narrow folder.
3. Files forbidden to edit.
4. Maximum number of files to change.
5. Tests/commands to run.
6. Success condition.
7. Stop condition.

Cursor must not be given vague instructions such as:

- “fix everything,”
- “continue until done,”
- “resolve all errors,”
- “search the whole repo and improve,”
- “make it production ready” without a bounded checklist.

Cursor must be kept on a leash. It should execute targeted changes, not explore indefinitely.

---

# 4. Retry Limits

For any failing task:

- Maximum 1 direct retry for a command that might have failed due to timing/network.
- Maximum 2 implementation attempts for the same bug.
- After 2 failed attempts, stop coding and switch to diagnosis.
- After diagnosis, produce a short evidence-based plan before editing again.

The engine must not loop through repeated build/test/fix cycles blindly.

---

# 5. Evidence Before Execution

Prefer cheap evidence before expensive action:

1. `git status`
2. targeted `grep` / `rg`
3. `sed -n` on specific files
4. `information_schema.columns` for database schema
5. dry-run modes
6. small targeted tests
7. only then broader build/test/deploy

Do not run full builds, full test suites, broad repo scans, or deployments when a targeted check can answer the question.

---

# 6. Token and Output Economy

The AI engine must:

- avoid dumping entire files unless necessary,
- inspect only relevant line ranges,
- prefer diffs over full file rewrites,
- summarize repeated evidence instead of reprinting it,
- avoid repeating previously confirmed facts,
- keep command blocks short and executable,
- avoid multi-screen speculative explanations during operational tasks,
- not ask the user to paste massive outputs when a narrower query will do.

---

# 7. Git Economy

Before editing:

- run `git status --short`,
- identify whether the repo is clean,
- avoid mixing unrelated changes,
- preserve user changes,
- do not overwrite large files blindly.

After editing:

- inspect `git diff --stat`,
- inspect targeted diff if needed,
- commit only intentional files,
- do not commit temp folders such as `supabase/.temp/`, logs, local secrets, screenshots, or downloaded zips.

---

# 8. Database Economy

Before production SQL:

- use read-only checks first,
- verify actual table/column names,
- use `limit`,
- test with one row where possible,
- avoid bulk updates without explicit approval,
- avoid migrations that touch unrelated objects.

The engine must not run destructive SQL to “clean up” uncertainty.

---

# 9. Deployment Economy

Before deploying:

1. Confirm the exact function/app being deployed.
2. Confirm the owner repo.
3. Confirm whether production or staging is targeted.
4. Confirm the deployment is necessary.
5. Prefer dry-run or local validation first.

Hard rule: do not redeploy `whatsapp-webhook` from AI Studio.

---

# 10. Build/Test Economy

Use the cheapest test that proves the change:

- specific unit test before full suite,
- typecheck before build if type risk is the concern,
- SQL readback before UI validation if DB persistence is the concern,
- UI smoke test only after backend evidence exists.

Run full build/test only at checkpoint points or before PR/merge.

---

# 11. Anti-Loop Pattern Recognition

The AI engine must recognize and stop these patterns:

- repeating the same failed SQL with guessed column names,
- repeatedly redeploying without reading logs,
- repeatedly changing UI when RLS is the actual issue,
- debugging Studio bridge when ERP webhook has no fresh rows,
- repeatedly asking Cursor to fix build errors without reading the first error,
- generating new architecture documents instead of updating existing canonical files,
- adding new screens instead of validating whether an existing screen already covers the feature.

---

# 12. Required Working Style

The engine must work in this order:

1. Identify the smallest unresolved question.
2. Use the cheapest read-only evidence to answer it.
3. Make the smallest safe change.
4. Validate with the narrowest sufficient test.
5. Stop and record status.

Never keep running because “more might be possible.”

---

# 13. Human Approval Required for Credit-Heavy Work

Ask before:

- full repo refactors,
- full app rewrites,
- broad design-system changes,
- mass screen generation,
- bulk schema rewrites,
- large Cursor agent runs,
- repeated failed debugging attempts,
- running long test/build/deploy loops,
- enabling cron/automation,
- production data backfills.

---

# 14. Cursor Prompt Template

When using Cursor, the next AI engine should use bounded prompts like this:

```txt
Objective: <one exact outcome>
Allowed files: <explicit files/folders>
Forbidden files: <explicit files/folders>
Do not change: secrets, RLS, migrations, unrelated screens, generated files.
Max files to edit: <number>
Validation command: <specific command>
Stop condition: stop after one failed validation attempt and report the exact error.
Output required: concise diff summary only.
```

---

# 15. One-Line Mandate

Use the least expensive path to the safest correct result; stop loops early; keep Cursor controlled; spend credits as if every unnecessary retry is a production loss.
