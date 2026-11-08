# WA-100 protected privacy release — live v175 source baseline (8 November 2026)

## Scope and current immutable facts

- Owning system: WhatsApp Module / Core, canonical mission [#450](https://github.com/oasisbaklawa2006/oasis-supabase-core/issues/450).
- Core production main at reconciliation: `645899439fe0a84806238b9114649eb2c3785a75`.
- Supabase project `tcxvcatsqqertcnycuop` was `ACTIVE_HEALTHY`; WhatsApp webhook `ACTIVE` **v175**, bundle **`7ee2d17f3cc3a55788c061737015d8dc484bdafa4d31709cf3fd853322e980d4`**.
- Protected v175 source release: [GitHub Actions #40749433490](https://github.com/oasisbaklawa2006/oasis-supabase-core/actions/runs/40749433490).
- This repair is **code and governance candidate only**. It does not prove consent, delivery, case ownership, WhatsApp live UAT or production activation.

## Candidate changes and dependency closure

- Existing protected **PR #473** redacts phone/name/raw provider payload logging and commercial company identifiers/invoice references/exception text, with source-level regression tests.
- The existing `WhatsApp Webhook Security` CI gate **executes** `supabase/functions/_shared/logRedaction.test.ts` on exact PR head (previously omitted).
- The *forward* `whatsapp-webhook-production-release.yml` must strictly pin **v175 and exact v175 bundle** before any next deployment. Preflight and deployment must fail if actual live state differs.
- On the next approved named release, the workflow captures the actual predeployment **v175** source and its file-closure SHA, uploads immutable rollback artifacts **before** deploying, and rechecks live source/baseline.
- Historical v167/v168/v173/v174 rollback workflows remain unchanged.
- **New** `whatsapp-webhook-production-rollback-v175.yml` is a dedicated *future* restore path using the same captured artifact, exact prior run and source SHA, deployed-source equality, no-customer negative authorization probes, separate protected `supabase-production` approval and final attestation.
- `scripts/check-whatsapp-webhook-production-release.sh` and its regression tests cover the new lane and reject stale old v174 forward pins.

## Mandatory no-bypass sequence

1. Confirm no other workstream has changed Core `main`, function v175 or the protected release configuration since this checkpoint; **repin again if live state advances**, do not force old pins.
2. Resolve `Supabase Preview` trust dependency on the exact PR head through the approved provider connection. The check currently reports `PREVIEW_NOT_PROVISIONED` because the trusted Supabase Preview check was skipped; **do not fake a preview/status or create a billable preview branch without approval**.
3. Obtain successful exact-head Deno checks, privacy regression, immutable workflow guard tests, CodeQL/Codacy/CodeRabbit and independent human code-owner review, with zero unresolved review threads.
4. After protected merge to then-current `main`, dispatch `WhatsApp Webhook Production Release` with **deploy=false** and the exact merged main SHA. Check preflight attestation and baseline, and ensure rollback artifacts are not represented as uploaded before they actually exist.
5. Request separate explicit **supabase-production** approval, then dispatch **deploy=true**. Allow only the named `whatsapp-webhook` function. Verify exact live source closure, Edge bundle/version, signature and negative HTTP probes, durable ledger integrity and authorized quiet-window behavior.
6. Record immutable run IDs, source closure and predeploy restore SHA; if postdeploy fails, do not launch any unapproved rollback automatically. Only the separately approved v175 rollback may be dispatched against the observed current version/bundle.
7. Keep WhatsApp **NO-GO** until staff AAL2, owner triage, provider consent/STOP, delivery/read callback, identity, governed Sales Order and 36-case live UAT all pass and independent certification signs off.

## Boundary conditions

No live customer messages or recipient identifiers are permitted as CI fixtures. Payment screenshots are evidence, not verified payment. Never publish secrets or customer data in issues, logs, artifacts or PR text. No migration, approval, production data mutation or provider send was performed by this runbook.
