# Agent Instructions

The Appverse programme is governed by Mission Control in `oasisbaklawa2006/Oasis-Baklawa-Central`. Preserve the assigned ASM work item, repository boundary, dependencies, and stop condition for every material task.

This repository is the canonical shared backend and the only Appverse repository allowed to own Supabase migration SQL.

If an instruction does not belong to the current Core ASM work item/thread, do not execute it. Start with `ROUTING REJECTED — instruction does not belong to this thread.`, identify the likely ASM route when possible, state `No code, PR, migration, deployment, or scope expansion performed.`, and stop.

If an upstream dependency or gate is missing, mark the work `BLOCKED` and stop at the last safe boundary. Do not invent schema, data, identifiers, bypasses, manual production SQL, migration-history rewrites, or parallel backend authority.

Cross-scope defects may be evidenced minimally, but must return to Mission Control for reassignment rather than being fixed opportunistically.

`PR MERGED != STAGE CLEARED`. Report the precise gate state; programme completion, not PR completion, is the objective.
