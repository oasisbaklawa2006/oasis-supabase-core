# APPVERSE THREAD / AGENT ROUTING GUARDRAIL — CORE

Canonical programme authority: `oasisbaklawa2006/Oasis-Baklawa-Central` → `APPVERSE_MISSION_CONTROL.md` and `appverse-control/state.json`.

## Repository authority

This repository is the **canonical shared backend authority and the only Appverse repository allowed to own Supabase migration SQL**. Do not move Core authority into Central, AI Studio, Trace, or Buyer App.

## Fail-closed routing

Every material task must belong to the current ASM work item/thread and to Core's backend authority. If a pasted instruction or agent response belongs to Central UI, Buyer App UX, AI Studio knowledge-plane implementation, Trace client work, or another workstream outside the current Core mission:

`ROUTING REJECTED — instruction does not belong to this thread.`

Identify the likely ASM route when evidence permits, state `No code, PR, migration, deployment, or scope expansion performed.`, and stop.

Do not silently expand scope because a cross-repo defect is discovered. Record minimal evidence and return it to Mission Control.

## Dependency rule

If an upstream dependency/gate is not satisfied, stop at the last safe boundary and report `BLOCKED`. Never fabricate schema/data/identities, bypass governance, apply manual production SQL, mutate migration history, or create a parallel authority.

## Clearance rule

`PR MERGED != STAGE CLEARED`. Report precise evidence: code merged, clean replay green, pgTAP green, production ledger verified, staging-certified, physical UAT pending, etc. Only Mission Control's declared stage gates may establish programme clearance.

## Instruction envelope

Preserve or infer from existing thread context: `ASM-ID`, `THREAD-ID`, `REPOSITORY`, `MISSION`, `DEPENDENCIES`, `STOP CONDITION`. Do not force the user to repeat values already clear from the current assignment.

## Return to Mission Control when

A gate is satisfied; a PR changes programme dependency state; a genuine blocker appears; cross-repo authority is required; merge-ready/merged is reached; or production/physical-device action becomes the remaining gate. Routine progress remains in the execution thread.
