# Genie G3 — protected forward-only resequence after WA-100 Core main

## Release candidate and provenance

This repair updates Core PR #555 after `main` advanced through the WA-100 order command migration `20261118110900`.
The preexisting isolated branch `sixxkkchadfmaizoeejc` already recorded eight historical Genie migration versions, including
the four previously executable `20261117150000`–`20261117150300`. That database's original applied SQL and ledger are **not**
rewritten. The applied historical code is preserved at Git commit `caf3509bf5faee338f20d1c952ed01022c28cfc8`.

| Preview-ledger historical version | Canonical forward-only executable version |
| --- | --- |
| `20261115160000`, `20261117150000` | `20261119010000`: transaction-bound Genie operation receipt and idempotent Cart insertion |
| `20261116120000`, `20261117150100` | `20261119010100`: Cart quantity compare-and-swap |
| `20261116140000`, `20261117150200` | `20261119010200`: operation receipt parity and constraints |
| `20261116160000`, `20261117150300` | `20261119010300`: checkout lock ordering and receipt index |

The eight historical files in canonical Git are **preview compatibility markers only**, containing `select 1;`, identified in
`supabase/preview-migration-ledger-compat.txt`. These are not a claim that the previously applied Preview SQL was inert.
Four executable forward migrations keep the previously reviewed SQL, with new versioned test and rollback references.

## Protected validation and deployment criteria

- Run base monotonicity, historical no-op marker rules, contract-test discovery, production overlay compatibility regression,
  clean database replay, pgTAP, and security analysis on the actual latest protected `main`.
- Confirm preview `sixxkkchadfmaizoeejc` does not receive a second unsafe Cart mutation or lose its existing committed receipts;
  compare schema/functions, constraints, ACLs and migration ledger before and after isolated replay.
- The preexisting isolation branch may use a different historical applied-SQL body for these versions. No branch ledger repair,
  `supabase migration repair`, function deployment or production SQL is authorized by this PR.
- Independent reviewer approval on the exact final PR head and separate `supabase-production` authorization remain required.
- Buyer Genie client feature enablement and cross-session / concurrent checkout tests are separate release gates; never treat
  sequential pgTAP tests as physical concurrency or UAT evidence.
- No customer WhatsApp provider calls or other outbound sends are part of this migration.

**Important:** If the exact-head checks detect a mismatch or schema drift, stop and produce a new additive migration after
the latest target-base ceiling. Never rewrite an existing applied SQL migration or suppress protected CI.
