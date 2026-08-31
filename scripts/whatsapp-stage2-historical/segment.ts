import type {
  CertificationWindow,
  ExpectedBusinessClass,
  ParsedHistoricalMessage,
} from "./types.ts";
import { inferExpectation } from "./expectations.ts";

const LINK_KEYWORDS =
  /\b(add|added|revised|revision|same order|previous|above|below|make it|qty|quantity|cancel|cancelled|dispatch|urgent|asap|balance|so\??|payment|paid|utr|for\s+[A-Z]|client waiting)\b/i;

function sharesCommercialContext(a: ParsedHistoricalMessage, b: ParsedHistoricalMessage): boolean {
  if (a.so_references.length && b.so_references.length) {
    return a.so_references.some((ref) => b.so_references.includes(ref));
  }
  if (a.party_hints.length && b.party_hints.length) {
    const al = new Set(a.party_hints.map((h) => h.toLowerCase()));
    return b.party_hints.some((h) => al.has(h.toLowerCase()));
  }
  if (a.sender === b.sender) return true;
  if (LINK_KEYWORDS.test(a.body) || LINK_KEYWORDS.test(b.body)) return true;
  if (a.mentions_evergreen && b.mentions_evergreen) return true;
  return false;
}

function isBusinessSignificant(message: ParsedHistoricalMessage): boolean {
  if (message.is_system) return false;
  if (message.is_deleted) return true;
  const body = message.body.toLowerCase();
  if (!body.trim()) return false;
  if (!body.trim()) return false;
  if (/^(ok|okay|thanks|thank you|noted|done|received|👍|🙏)\.?$/i.test(body.trim())) {
    return true;
  }
  return true;
}

function collectContextIndices(
  messages: ParsedHistoricalMessage[],
  focalIndex: number,
  maxBefore = 4,
  maxAfter = 2,
): number[] {
  const byIndex = new Map(messages.map((m) => [m.index, m]));
  const focal = byIndex.get(focalIndex);
  if (!focal) return [focalIndex];

  const selected = new Set<number>([focalIndex]);

  for (let i = focalIndex - 1, seen = 0; i >= 1 && seen < maxBefore; i--) {
    const candidate = byIndex.get(i);
    if (!candidate || candidate.is_system) continue;
    if (!sharesCommercialContext(focal, candidate) && seen > 0) break;
    selected.add(i);
    seen++;
  }

  for (let i = focalIndex + 1, seen = 0; i <= messages.length && seen < maxAfter; i++) {
    const candidate = byIndex.get(i);
    if (!candidate || candidate.is_system) continue;
    if (!sharesCommercialContext(focal, candidate) && seen > 0) break;
    selected.add(i);
    seen++;
  }

  return [...selected].sort((a, b) => a - b);
}

function evergreenClusterId(message: ParsedHistoricalMessage): string | null {
  if (!message.mentions_evergreen) return null;
  return `evergreen-${message.index}`;
}

export function buildCertificationWindows(
  messages: ParsedHistoricalMessage[],
): CertificationWindow[] {
  const windows: CertificationWindow[] = [];

  for (const message of messages) {
    if (message.is_system) continue;
    if (!isBusinessSignificant(message)) continue;

    const contextIndices = collectContextIndices(messages, message.index);
    const expectation = inferExpectation(message, messages, contextIndices);
    const window_id = `win-${message.index}-${expectation.expected_class.toLowerCase()}`;

    windows.push({
      window_id,
      focal_index: message.index,
      message_indices: contextIndices,
      sender: message.sender,
      commercial_party_hint: message.party_hints[0] ?? null,
      expected_class: expectation.expected_class,
      expected_core_outcome: expectation.expected_core_outcome,
      should_auto_action: expectation.should_auto_action,
      traffic_class: expectation.traffic_class,
      linkage_reasons: expectation.linkage_reasons,
      evergreen_cluster_id: evergreenClusterId(message),
    });
  }

  return windows;
}

export function countEvergreenWindows(windows: CertificationWindow[]): number {
  return windows.filter((w) => w.evergreen_cluster_id != null).length;
}

export function distributionByClass(
  windows: CertificationWindow[],
): Record<ExpectedBusinessClass, number> {
  const dist = {} as Record<ExpectedBusinessClass, number>;
  for (const window of windows) {
    dist[window.expected_class] = (dist[window.expected_class] ?? 0) + 1;
  }
  return dist;
}
