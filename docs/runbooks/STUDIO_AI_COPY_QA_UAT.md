# Studio AI-copy — isolated QA, inert source and protected UAT sequence

**As of 22 November 2026: SOURCE-ONLY READ-ONLY PREPARATION; NO QA WRITE OR DEPLOYMENT.**

The billable Dashboard Preview `sefkuceukuulfgliaruw` was deleted after historical migration bootstrap failed (Core #495). Repeating that method is prohibited. The existing independently governed `oasis-genie-qa` project `skhpmltfjgqitntkmclb` has 516 canonical migrations, 392 public tables, one required WhatsApp system principal, both Studio authorization RPCs, zero outbound database extensions, and zero Edge Functions at the read-only checkpoint. This is shared QA infrastructure, **not an exclusive Studio lease**.

## Reviewed source boundary

`scripts/studio-qa/build_inert_copy.py` renders an **ephemeral** two-file QA closure from reviewed Core main. It preserves the entire original authentication/Studio permission/request-validation prefix, except for replacing the Origin configuration with a fixed synthetic `https://studio-qa.oasis.invalid` test header. It cuts off everything after `const apiKey = Deno.env.get("OPENAI_API_KEY");` and replaces the entire provider path with deterministic HTTP 503. It refuses source drift, duplicate expected anchors, unexpected early `fetch()`, or missing scoped `ai_studio.ai.use` check. The shared helper is copied byte-for-byte. The generated QA bundle has **no direct fetch or provider credential reference**. This output must **never** be merged into production source or released to Production.

## Protected read-only preflight only

The workflow `.github/workflows/studio-ai-copy-qa-preflight.yml` is manual `workflow_dispatch` on exact protected Core main, environment `genie-qa-bootstrap`, expected SHA and a structured `Core#495/Studio#240;QA-PREFLIGHT=...` justification. It checks:
- reviewed source and negative security regressions, canonical candidate file closure and JWT mode;
- QA-only direct Postgres/TLS with no secret exposure, exactly 516 expected applied schema versions and no-eject canonical no-egress state;
- no QA synthetic staff, a single untouched preexisting system service account, no sessions or refresh tokens;
- QA-only Edge Management API list empty (to avoid stealing Genie #585 environment);
- complete QA secret inventory available, **no non-platform custom secrets**, no unverified provider credentials;
- immutable current `main` before and after inspection.

The workflow never creates a user, uploads an Edge Function, sets secrets, applies SQL, invokes a provider or contacts customers. No source artifact is published; the only retained artifact is the sanitized offline candidate manifest.

## Release blocker and future separately approved steps

**Do not add a deploy step by hand to the currently reviewed workflow.** Genie QA #585's protected deploy job deliberately hard-stops with `GENIE_QA_EDGE_EXCLUSIVE_WRITER_HOLD`. GitHub concurrency does not control Dashboard/API writers; neither a zero-Edge count nor single GitHub environment approval gives an exclusive writer lock. Studio and Genie workflows also conflict over the shared QA zero-function invariant. A separate CODEOWNER-reviewed PR, owner scope/lease approval, independent protected environment reviewer and verified external-writer control must govern any **named-function QA-only deployment**, with before/after QA function list, source manifest and JWT, and an approved rollback/removal window. If exclusive writer protection cannot be demonstrated, use a separate owner-approved canonical standalone QA instead.

Only after a protected, inert QA-specific deployment may temporary, disposable users be provisioned via approved Auth admin and Studio-access paths. Execute three sanitized requests with the real QA project's valid Auth-issued JWT and the synthetic Origin:
1. Active internal staff, active Studio membership, app.access and `ai_studio.ai.use`, valid JSON body: HTTP **503**, no provider path
2. Active internal staff without `ai_studio.ai.use`: HTTP **401**
3. Revoke Studio membership/permission on actor 1 while retaining their JWT: HTTP **401**

Inspect and record server-side body/status, JWT-enabled function metadata, request source hash and zero outbound activity; no credentials, tokens or PII in GitHub evidence. Delete synthetic Auth users and Studio access fixtures, reconcile sessions and no other changes, and restore Genie QA's Edge-zero requirement via separately approved rollback/remove if it is in force. Do not mark Production source as deployed. Production `catalogue-ai-copy` v44 remains behind its separate protected release workflow and Production environment/secret approval.
