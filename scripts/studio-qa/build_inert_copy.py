#!/usr/bin/env python3
"""Render an inert QA-only AI-copy bundle, without changing canonical Core source.

The authorization and request-validation prefix remains byte-identical except
for the fixed synthetic QA Origin, removal of provider-only imports and
provider-only SYSTEM_PROMPT, and discard of the parsed provider input binding.
The entire provider suffix is removed.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil

QA_ORIGIN = "https://studio-qa.oasis.invalid"
# Reviewed Core main source closure. Any source change needs a new independent review.
APPROVED_INDEX_SHA256 = "0e1c3c993019241d1564a572dd8c147f1ed37df472c8900d822eee7c09ab97f1"
APPROVED_HELPER_SHA256 = "14ad8137c2bf345f209e271024f52c8171290210cac8a891e5677a99965f47fd"
ORIGIN_LINE = 'const configured = Deno.env.get("AI_STUDIO_ALLOWED_ORIGIN")?.trim();'
PROVIDER_BOUNDARY = '  const apiKey = Deno.env.get("OPENAI_API_KEY");'
# Only imports exclusively used by the removed provider suffix are removed.
# Their exact source occurrence is verified after the index SHA-256 check.
PROVIDER_ONLY_IMPORTS = (
    "  buildCatalogueCopyPrompt,\n",
    "  buildGovernedCatalogueCopyResponse,\n",
    "  catalogueCopyJsonSchema,\n",
    "  extractResponsesText,\n",
    "  validateCatalogueCopy,\n",
    # APPVERSE-CORE-AI-BUDGET-01: the budget orchestrator is used only by the removed provider suffix.
    'import {\n  type Accounting,\n  APPROVED_MODEL,\n  buildProviderRequests,\n  COUNT_TIMEOUT_MS,\n'
    '  INFERENCE_TIMEOUT_MS,\n  type ProviderReply,\n  runBudgetedInference,\n'
    '} from "../_shared/catalogueAiCopyBudget.ts";\n',
)
END_MARKER = '\n});'
INERT_TAIL = (
    '  // QA-ONLY: provider pathway deliberately absent from this bundle.\n'
    '  // Authorization and input validation above are the reviewed Core code.\n'
    '  return json({ ok: false, error: "AI service is not configured" }, 503, origin);\n'
    '});\n'
)


class OverlayDenied(ValueError):
    """Source no longer satisfies the reviewed immutable authorization boundary."""


def render_inert(source: str) -> str:
    if not isinstance(source, str):
        raise OverlayDenied("source must be reviewed text")
    # A marker list is never a security boundary: fetch aliases, Deno.connect,
    # imports, and computed properties can evade text scans. Only the exact
    # independently reviewed source is eligible for QA synthesis.
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != APPROVED_INDEX_SHA256:
        raise OverlayDenied("canonical Catalogue AI source digest has changed")
    if source.count(ORIGIN_LINE) != 1:
        raise OverlayDenied("approved Origin anchor missing or repeated")
    if source.count(PROVIDER_BOUNDARY) != 1:
        raise OverlayDenied("provider cut boundary missing or repeated")
    if not source.endswith(END_MARKER + "\n"):
        raise OverlayDenied("unexpected end of handler")
    prefix, provider = source.split(PROVIDER_BOUNDARY, 1)
    if not (source.count('fetch("https://api.openai.com/v1/responses"') == 1
            and "const controller = new AbortController()" in provider
            and "clearTimeout(timeout)" in provider):
        raise OverlayDenied("original provider code changed")
    required = (
        'client.rpc(\n    "is_internal_staff"',
        '"has_ai_studio_permission_v1"',
        '{ p_key: "ai_studio.ai.use" }',
        "const userId = await authenticatedStaff(req);",
        "parseCatalogueCopyRequest(await req.json())",
        "if (!userId) return json({ ok: false, error: \"unauthorized\" }, 401, origin);",
    )
    if not all(fragment in prefix for fragment in required):
        raise OverlayDenied("reviewed authorization or request validation missing")
    if "fetch(" in prefix or "api.openai.com" in prefix:
        raise OverlayDenied("unexpected earlier network call")
    # Tail begins AFTER all identity, permission and input validation. No
    # provider call can occur even if every environment flag is modified later.
    sanitized_prefix = prefix.replace(ORIGIN_LINE, f'const configured = "{QA_ORIGIN}";')
    for import_line in PROVIDER_ONLY_IMPORTS:
        if sanitized_prefix.count(import_line) != 1:
            raise OverlayDenied("reviewed provider-only import missing or duplicated")
        sanitized_prefix = sanitized_prefix.replace(import_line, "", 1)
    # SYSTEM_PROMPT is consumed only by the removed OpenAI suffix.
    prompt_start = "const SYSTEM_PROMPT =\n"
    prompt_end = "\nfunction allowedOrigin(req: Request): string | null {"
    if sanitized_prefix.count(prompt_start) != 1 or sanitized_prefix.count(prompt_end) != 1:
        raise OverlayDenied("reviewed provider-only system prompt boundary changed")
    begin = sanitized_prefix.index(prompt_start)
    end = sanitized_prefix.index(prompt_end)
    if end <= begin:
        raise OverlayDenied("invalid provider-only prompt position")
    sanitized_prefix = sanitized_prefix[:begin] + sanitized_prefix[end + 1:]
    # Keep the same parseCatalogueCopyRequest operation and exceptions. Only
    # discard its result: QA has no inference provider that could consume it.
    input_binding = "  let input;\n  try {\n    input = parseCatalogueCopyRequest(await req.json());"
    input_validation = "  try {\n    parseCatalogueCopyRequest(await req.json());"
    if sanitized_prefix.count(input_binding) != 1:
        raise OverlayDenied("reviewed provider input binding changed")
    sanitized_prefix = sanitized_prefix.replace(input_binding, input_validation, 1)
    rendered = sanitized_prefix + INERT_TAIL
    if any(token in rendered for token in ("fetch(", "api.openai.com", "OPENAI_API_KEY",
                                          "AI_STUDIO_AI_ENABLED", "OPENAI_CATALOGUE_MODEL")):
        raise OverlayDenied("provider feature or network dependency survived")
    if rendered.count('const configured = "https://studio-qa.oasis.invalid";') != 1:
        raise OverlayDenied("invalid synthetic Origin")
    return rendered


def build(source: Path, helper: Path, output_dir: Path) -> None:
    raw = source.read_text(encoding="utf-8")
    rendered = render_inert(raw)
    helper_bytes = helper.read_bytes()
    if hashlib.sha256(helper_bytes).hexdigest() != APPROVED_HELPER_SHA256:
        raise OverlayDenied("shared helper digest differs from the reviewed source")
    helper_source = helper_bytes.decode("utf-8")
    if "canGenerateStudioAiCopy" not in helper_source:
        raise OverlayDenied("Studio helper source missing")
    # Closure-wide no-egress proof: the reviewed helper is copied byte-for-byte,
    # but can no longer silently introduce an outbound transport or provider.
    forbidden_helper_markers = (
        "fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "Deno.env",
        "globalThis", "import(", "http://", "https://", "eval(", "Function(",
    )
    if any(marker in helper_source for marker in forbidden_helper_markers):
        raise OverlayDenied("unexpected helper network/provider capability")
    target = output_dir / "catalogue-ai-copy" / "index.ts"
    shared = output_dir / "_shared" / "catalogueAiCopy.ts"
    if target.exists() or shared.exists():
        raise OverlayDenied("refusing to overwrite existing QA source")
    target.parent.mkdir(parents=True, exist_ok=True)
    shared.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(rendered, encoding="utf-8")
    shutil.copyfile(helper, shared)
    if shared.read_bytes() != helper.read_bytes():
        raise OverlayDenied("shared helper changed during source materialization")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        build(args.source, args.helper, args.output_dir)
    except (OSError, UnicodeError, OverlayDenied):
        print("STUDIO_QA_INERT_SOURCE_DENIED")
        return 1
    print("STUDIO_QA_INERT_SOURCE_RENDERED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
