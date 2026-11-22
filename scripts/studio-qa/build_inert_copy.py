#!/usr/bin/env python3
"""Render an inert QA-only AI-copy bundle, without changing canonical Core source.

The authorization and request-validation prefix is preserved byte for byte
except for a fixed synthetic QA Origin. The entire provider suffix is removed.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil

QA_ORIGIN = "https://studio-qa.oasis.invalid"
ORIGIN_LINE = 'const configured = Deno.env.get("AI_STUDIO_ALLOWED_ORIGIN")?.trim();'
PROVIDER_BOUNDARY = '  const apiKey = Deno.env.get("OPENAI_API_KEY");'
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
    if not isinstance(source, str) or source.count(ORIGIN_LINE) != 1:
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
    rendered = prefix.replace(ORIGIN_LINE, f'const configured = "{QA_ORIGIN}";') + INERT_TAIL
    if any(token in rendered for token in ("fetch(", "api.openai.com", "OPENAI_API_KEY",
                                          "AI_STUDIO_AI_ENABLED", "OPENAI_CATALOGUE_MODEL")):
        raise OverlayDenied("provider feature or network dependency survived")
    if rendered.count('const configured = "https://studio-qa.oasis.invalid";') != 1:
        raise OverlayDenied("invalid synthetic Origin")
    return rendered


def build(source: Path, helper: Path, output_dir: Path) -> None:
    raw = source.read_text(encoding="utf-8")
    rendered = render_inert(raw)
    helper_source = helper.read_text(encoding="utf-8")
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
