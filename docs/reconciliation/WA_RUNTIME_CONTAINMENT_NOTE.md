# WA Runtime Containment Note

During physical WhatsApp certification, a stale deployed `banyan-central-parser` was proven to be an independent outbound authority. It was invoked by the active `banyan-flush-buffer` schedule and emitted the exact unsolicited onboarding response observed on the handset.

The deployed function was replaced with a minimal HTTP 410 retirement stub. This was containment, not migration-history repair: no WhatsApp message, commercial evidence, order, or audit history was deleted or rewritten.

Canonical release governance must ensure future deployed Banyan versions remain retired and that outbound WhatsApp is issued only through the governed operator-reply path.
