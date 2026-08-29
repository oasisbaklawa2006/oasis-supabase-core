# WA direct Gemini provider implementation plan

Authority: issue #137 / ASM 06 WA-01.

This branch replaces the Lovable AI Gateway dependency in `whatsapp-packet-ai-worker` with a direct Gemini API adapter using `GEMINI_API_KEY`. The implementation must preserve governed media fetching, MIME/byte limits, evidence provenance, active knowledge snapshot authority, sanitizer/persistence/lease/idempotency/media-completion/materialization/retry semantics, and all fail-closed commercial invariants.

Provider contract checkpoint (2026-08-29): Google documents `gemini-3.7-flash` as the current Flash model and the Gemini GenerateContent API still supports `inlineData` for image/audio/video/PDF plus JSON response mode. Although Google now recommends the Interactions API for new integrations, issue #137 intentionally freezes this narrow change to the supported `v1beta/models/{model}:generateContent` contract to minimize scope during certification recovery.

Required source work before this branch may become merge-ready:

- Replace `LOVABLE_API_KEY` with `GEMINI_API_KEY`; missing key returns `WORKER_NOT_CONFIGURED`.
- Remove Lovable chat/transcription endpoints and the separate OpenAI transcription path.
- Send text and all governed media directly as Gemini `parts`, using `inlineData` for image/audio/video/PDF.
- Use `gemini-3.7-flash` and `generationConfig.responseMimeType = application/json`, deterministic temperature, and bounded output tokens.
- Parse Gemini `candidates[0].content.parts[*].text`; reject provider errors, missing/empty candidates, empty text, and invalid JSON.
- Persist accurate direct-provider/model identity in interpretation and media-completion detail.
- Add deterministic tests covering text, image, audio, video, PDF, missing key, timeouts/provider failures, empty responses, invalid JSON, and malformed payloads without live credentials.
- No production deploy. After clean CI/review and merge, refresh certification PR #126 and deploy only to preview `dfjslkwxawnzurolifpm`.
