# WA Packet Authority Rollback Posture

This is a forward-only migration. Do not delete or rewrite the production migration ledger to roll it back.

If a defect is found before release, do not deploy. If a defect is found after deployment, ship a new append-only migration that revokes/replaces the RPC or index as required while preserving message/evidence history. Historical fragmented packet rows are not modified by this change.
