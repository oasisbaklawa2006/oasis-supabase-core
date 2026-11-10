const EXPECTED_URL = "https://stkvyotdkysieuvpuues.supabase.co";

/** Fail closed for every business request, without inspecting credentials or bodies. */
export function denyPreviewRequest(request, runtimeUrl) {
  const headers = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  };
  if (runtimeUrl !== EXPECTED_URL) {
    return new Response(JSON.stringify({ error: "wrong_isolation_project" }), {
      status: 403,
      headers,
    });
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }
  return new Response(JSON.stringify({ error: "preview_edge_quarantined" }), {
    status: 503,
    headers,
  });
}
