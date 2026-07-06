import type { RuntimeCatalog, RuntimeCatalogAlias, RuntimeCatalogProduct } from "./types.ts";

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean);
}

export type CatalogLexiconEntry = {
  product_id: string;
  sku: string;
  resolved_name: string;
  search_text: string;
  name_tokens: string[];
  terms: Array<{ text: string; tokens: string[]; source: "sku" | "name" | "short_name" | "alias" | "canonical_name" | "category" | "subcategory" }>;
};

export function buildCatalogLexicon(catalog: RuntimeCatalog): CatalogLexiconEntry[] {
  const aliasesByProduct = new Map<string, RuntimeCatalogAlias[]>();
  for (const alias of catalog.aliases) {
    const list = aliasesByProduct.get(alias.product_id) ?? [];
    list.push(alias);
    aliasesByProduct.set(alias.product_id, list);
  }

  return catalog.products.map((product) => {
    const resolved_name = product.product_name ?? product.name;
    const terms: CatalogLexiconEntry["terms"] = [];

    const addTerm = (text: string, source: CatalogLexiconEntry["terms"][number]["source"]) => {
      const trimmed = text.trim();
      if (!trimmed) return;
      terms.push({ text: trimmed, tokens: tokenize(trimmed), source });
    };

    addTerm(product.sku, "sku");
    addTerm(product.name, "name");
    if (product.product_name) addTerm(product.product_name, "name");
    if (product.short_name) addTerm(product.short_name, "short_name");
    if (product.category) addTerm(product.category, "category");
    if (product.subcategory) addTerm(product.subcategory, "subcategory");

    for (const alias of aliasesByProduct.get(product.id) ?? []) {
      addTerm(alias.alias_text, "alias");
      addTerm(alias.canonical_name, "canonical_name");
    }

    const search_text = [
      product.sku,
      product.name,
      product.product_name,
      product.short_name,
      product.category,
      product.subcategory,
      ...(aliasesByProduct.get(product.id) ?? []).flatMap((a) => [a.alias_text, a.canonical_name]),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();

    return {
      product_id: product.id,
      sku: product.sku,
      resolved_name,
      search_text,
      name_tokens: tokenize(resolved_name),
      terms,
    };
  });
}
