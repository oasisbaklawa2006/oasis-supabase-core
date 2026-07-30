# Migration Release Architecture

```text
Migration PR
  -> static governance
  -> clean replay
  -> pgTAP contracts
  -> merge to Core main
  -> read-only production ledger verification
  -> Supabase CLI dry run
  -> protected production approval
  -> serialized db push
  -> exact ledger equality check
  -> read-only contract smoke
  -> immutable evidence artifact
  -> daily drift watch
```

## Invariants

1. Core `main` is the sole production migration writer.
2. Production-only migration versions stop the pipeline.
3. Pending versions must be newer than the latest production version.
4. Migration history is never repaired automatically.
5. Deployment is serialized; concurrent pushes are impossible within the workflow.
6. The production project reference is hard-checked before every database operation.
7. The exact approved commit is deployed.
8. A release is incomplete until local and remote version sets are identical.
9. Manual dashboard SQL is treated as drift and an incident.
10. The daily sentinel catches gaps even when no repository event occurs.
