import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  buildGeminiRequest,
  callGeminiGenerateContent,
  GEMINI_GENERATE_CONTENT_URL,
  GEMINI_MODEL,
  GEMINI_TIMEOUT_MS,
  inlineMediaPart,
  parseGeminiJsonText,
  textPart,
} from "./geminiProvider.ts";

Deno.test("direct Gemini provider uses current frozen model and generateContent endpoint", () => {
  assertEquals(GEMINI_MODEL, "gemini-3.7-flash");
  assertEquals(GEMINI_TIMEOUT_MS, 90_000);
  assertStringIncludes(
    GEMINI_GENERATE_CONTENT_URL,
    "/v1beta/models/gemini-3.7-flash:generateContent",
  );
});

Deno.test("request construction preserves text and inline image/audio/video/pdf evidence", () => {
  const bytes = new Uint8Array([1, 2, 3]);
  const request = buildGeminiRequest([
    textPart("governed prompt"),
    inlineMediaPart(bytes, "image/png"),
    inlineMediaPart(bytes, "audio/ogg"),
    inlineMediaPart(bytes, "video/mp4"),
    inlineMediaPart(bytes, "application/pdf"),
  ]);
  assertEquals(request.generationConfig.responseMimeType, "application/json");
  assertEquals(request.generationConfig.maxOutputTokens, 3600);
  assertEquals("temperature" in request.generationConfig, false);
  assertEquals(request.contents[0].parts.length, 5);
  assertEquals(request.contents[0].parts[1], {
    inlineData: { mimeType: "image/png", data: "AQID" },
  });
  assertEquals(request.contents[0].parts[2], {
    inlineData: { mimeType: "audio/ogg", data: "AQID" },
  });
  assertEquals(request.contents[0].parts[3], {
    inlineData: { mimeType: "video/mp4", data: "AQID" },
  });
  assertEquals(request.contents[0].parts[4], {
    inlineData: { mimeType: "application/pdf", data: "AQID" },
  });
});

Deno.test("empty Gemini request fails closed", () => {
  try {
    buildGeminiRequest([]);
    throw new Error("EXPECTED_REJECTION");
  } catch (error) {
    assertEquals((error as Error).message, "INTERPRETER_REQUEST_EMPTY");
  }
});

Deno.test("Gemini response parser joins textual candidate parts", () => {
  assertEquals(
    parseGeminiJsonText({
      candidates: [{
        content: { parts: [{ text: "{\"ok\":" }, { text: "true}" }] },
      }],
    }),
    "{\"ok\":true}",
  );
});

Deno.test("Gemini response parser accepts optional markdown JSON fences", () => {
  assertEquals(
    parseGeminiJsonText({
      candidates: [{ content: { parts: [{ text: "```json\n{\"ok\":true}\n```" }] } }],
    }),
    "{\"ok\":true}",
  );
  assertEquals(
    parseGeminiJsonText({
      candidates: [{ content: { parts: [{ text: "```\n{\"ok\":true}\n```" }] } }],
    }),
    "{\"ok\":true}",
  );
});

Deno.test("Gemini response parser fails closed on malformed or empty payload", async () => {
  await assertRejects(
    async () => parseGeminiJsonText({}),
    Error,
    "INTERPRETER_EMPTY_RESPONSE",
  );
  await assertRejects(
    async () => parseGeminiJsonText({ candidates: [{ content: {} }] }),
    Error,
    "INTERPRETER_EMPTY_RESPONSE",
  );
});

Deno.test("direct provider requires transferable Gemini key", async () => {
  await assertRejects(
    () => callGeminiGenerateContent("", buildGeminiRequest([textPart("x")])),
    Error,
    "WORKER_NOT_CONFIGURED",
  );
});

Deno.test("direct provider sends x-goog-api-key and parses JSON text", async () => {
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const fakeFetch: typeof fetch = (input, init) => {
    capturedUrl = String(input);
    capturedInit = init;
    return Promise.resolve(
      new Response(
        JSON.stringify({
          candidates: [{
            content: { parts: [{ text: "{\"intent\":\"OTHER\"}" }] },
          }],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
  };
  const text = await callGeminiGenerateContent(
    "preview-key",
    buildGeminiRequest([textPart("x")]),
    fakeFetch,
  );
  assertEquals(text, "{\"intent\":\"OTHER\"}");
  assertEquals(capturedUrl, GEMINI_GENERATE_CONTENT_URL);
  assertEquals(
    new Headers(capturedInit?.headers).get("x-goog-api-key"),
    "preview-key",
  );
});

Deno.test("provider HTTP failure is explicit and has no fallback", async () => {
  const fakeFetch: typeof fetch = () =>
    Promise.resolve(new Response("no", { status: 429 }));
  await assertRejects(
    () =>
      callGeminiGenerateContent(
        "key",
        buildGeminiRequest([textPart("x")]),
        fakeFetch,
      ),
    Error,
    "INTERPRETER_PROVIDER_429",
  );
});

Deno.test("provider malformed response fails closed", async () => {
  const fakeFetch: typeof fetch = () =>
    Promise.resolve(new Response("not-json", { status: 200 }));
  await assertRejects(
    () =>
      callGeminiGenerateContent(
        "key",
        buildGeminiRequest([textPart("x")]),
        fakeFetch,
      ),
    Error,
    "INTERPRETER_PROVIDER_MALFORMED",
  );
});

Deno.test("provider timeout failure is explicit", async () => {
  const fakeFetch: typeof fetch = () =>
    Promise.reject(new DOMException("timed out", "TimeoutError"));
  await assertRejects(
    () =>
      callGeminiGenerateContent(
        "key",
        buildGeminiRequest([textPart("x")]),
        fakeFetch,
      ),
    Error,
    "INTERPRETER_PROVIDER_TIMEOUT",
  );
});

Deno.test("provider transport failure fails closed", async () => {
  const fakeFetch: typeof fetch = () => Promise.reject(new Error("network"));
  await assertRejects(
    () =>
      callGeminiGenerateContent(
        "key",
        buildGeminiRequest([textPart("x")]),
        fakeFetch,
      ),
    Error,
    "INTERPRETER_PROVIDER_TRANSPORT",
  );
});
