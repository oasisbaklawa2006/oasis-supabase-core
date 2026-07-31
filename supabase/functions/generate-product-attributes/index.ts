const RETIREMENT_MESSAGE =
  "This endpoint has been retired. Use the authenticated catalogue-ai-copy workflow and verified product master data instead.";
const RETIRED_RESPONSE = { status: 410 } as const;

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

Deno.serve((req) => {
  if (req.method === "OPTIONS") {
    return json({ ok: false, error: "endpoint retired" }, RETIRED_RESPONSE.status);
  }

  return json(
    {
      ok: false,
      retired: true,
      replacement: "catalogue-ai-copy",
      error: RETIREMENT_MESSAGE,
    },
    RETIRED_RESPONSE.status,
  );
});
