// Static contract notes for runtime certification.
// The repository's Edge Function validation and staging physical tests cover the executable path.
//
// Required cases:
// 1. unauthenticated request -> 401
// 2. provider_message_id absent -> 400
// 3. caller cannot read provider message under RLS -> 404
// 4. ordinary English text -> returned unchanged without model call
// 5. Devanagari text -> normalized text, no invented quantity/product
// 6. image -> server-side provider fetch, bounded supported mime/size, multimodal interpretation
// 7. unsupported/oversized image -> fail closed
// 8. interpreter/provider failure -> no mutation to original evidence

export {};
