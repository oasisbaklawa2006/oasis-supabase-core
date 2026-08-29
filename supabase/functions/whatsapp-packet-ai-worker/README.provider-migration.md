# Direct provider migration status

Issue #137 tracks the bounded WhatsApp inference transport replacement.

The direct Gemini adapter and deterministic transport/request/response tests live in `geminiProvider.ts` and `geminiProvider.test.ts`. The worker must not be considered migrated until `index.ts` imports this adapter, constructs Gemini parts from the already-governed media bytes, reads `GEMINI_API_KEY`, removes the Lovable/OpenAI gateway paths, and records `gemini-3.7-flash` as the provider model in the existing governed persistence/media-completion metadata.

Until that integration commit lands, this branch is intentionally draft/incomplete and must not be merged or deployed.
