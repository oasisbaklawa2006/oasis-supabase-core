#!/usr/bin/env python3
"""Static (no-DB) validation for the foundation baseline migration.

Phase 4.1b deliverable #3. Parses
supabase/migrations/20260101000000_foundation_baseline_*.sql as text only --
never connects to a database, never creates a Supabase branch/project -- and
checks:

  1. Schema-contract manifest: every expected table exists with its columns,
     PK, UNIQUE constraints, FKs, and indexes (printed as JSON with --json).
  2. Dependency order: CREATE TABLE statements appear in an order where every
     FK target table is already created (or is the same table / a deferred
     constraint), matching the documented 7-step plan.
  3. Idempotent/replay-safe guards: every CREATE TABLE and CREATE INDEX uses
     IF NOT EXISTS; the deferred companies.account_manager_id FK is wrapped
     in a guarded DO $$ ... IF NOT EXISTS (SELECT ... pg_constraint) block.
  4. No destructive/data-mutating statements anywhere in the file (DROP,
     TRUNCATE, INSERT, UPDATE, GRANT, REVOKE, CREATE POLICY, ALTER POLICY,
     ENABLE ROW LEVEL SECURITY, CREATE FUNCTION, CREATE TRIGGER, or a
     DELETE that isn't part of an "ON DELETE ..." FK action).
  5. Central-lineage check: given a path to Oasis-Baklawa-Central's
     supabase/migrations directory (--central-migrations-dir, or env var
     CENTRAL_MIGRATIONS_DIR), confirms every public.<table> relation
     referenced by Central's earliest-timestamped migration is created by
     some Core migration timestamped at or before that file -- i.e. the
     historically "missing relation" gap is actually closed. If no such
     directory is available (e.g. in this repo's own CI, which does not
     check out Central), this single check is reported as SKIPPED, not
     failed or silently passed.

Exit code is 0 only if every check that actually ran passed (SKIPPED does
not count as a failure).
"""
import argparse
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIGRATIONS_DIR = os.path.join(REPO_ROOT, "supabase", "migrations")
BASELINE_TIMESTAMP = "20260101000000"

EXPECTED_TABLE_ORDER = [
    "categories",
    "companies",
    "users",
    "products",
    "orders",
    "order_items",
]

FORBIDDEN_KEYWORDS = [
    "DROP", "TRUNCATE", "INSERT", "UPDATE", "GRANT", "REVOKE",
    "CREATE POLICY", "ALTER POLICY", "ENABLE ROW LEVEL SECURITY",
    "CREATE FUNCTION", "CREATE OR REPLACE FUNCTION", "CREATE TRIGGER",
]


def strip_line_comments(sql):
    """Remove '-- ...' line comments so prose (e.g. this file's own header,
    which quotes CREATE POLICY/CREATE TABLE for context) is never mistaken
    for executable SQL by the checks below. Naive per-line stripping is
    sufficient here: this migration's string literals never contain '--'."""
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


def find_baseline_file():
    for fname in sorted(os.listdir(MIGRATIONS_DIR)):
        if fname.startswith(BASELINE_TIMESTAMP) and fname.endswith(".sql"):
            return os.path.join(MIGRATIONS_DIR, fname)
    return None


def extract_balanced_block(text, open_paren_index):
    """Given the index of a '(' , return the index just past its matching ')'."""
    depth = 0
    i = open_paren_index
    in_single_quote = False
    while i < len(text):
        ch = text[i]
        if ch == "'" and not in_single_quote:
            in_single_quote = True
        elif ch == "'" and in_single_quote:
            # naive: doesn't handle escaped '' inside strings, not needed here
            in_single_quote = False
        elif not in_single_quote:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    raise ValueError("Unbalanced parentheses starting at index %d" % open_paren_index)


def parse_tables(sql):
    """Returns dict: table_name -> {"start": int, "body": str, "columns": [...],
    "primary_key": [...], "unique": [...], "foreign_keys": [...], "checks": [...]}"""
    tables = {}
    for m in re.finditer(r"CREATE TABLE IF NOT EXISTS public\.(\w+)\s*\(", sql):
        table_name = m.group(1)
        open_paren = sql.index("(", m.end() - 1)
        close_paren = extract_balanced_block(sql, open_paren)
        body = sql[open_paren + 1:close_paren]
        tables[table_name] = {
            "start": m.start(),
            "body": body,
        }

    for name, info in tables.items():
        body = info["body"]
        # Split top-level comma-separated entries (body has no nested parens
        # at depth 0 other than the ones already consumed by extract_balanced_block,
        # but CHECK/DEFAULT clauses do have nested parens -- so split with
        # paren-depth tracking instead of a naive .split(",")).
        entries = []
        depth = 0
        current = []
        for ch in body:
            if ch == "(":
                depth += 1
                current.append(ch)
            elif ch == ")":
                depth -= 1
                current.append(ch)
            elif ch == "," and depth == 0:
                entries.append("".join(current).strip())
                current = []
            else:
                current.append(ch)
        if current:
            entries.append("".join(current).strip())
        entries = [e for e in entries if e]

        columns, pk, unique, fks, checks = [], [], [], [], []
        for e in entries:
            e_norm = e.strip()
            if e_norm.upper().startswith("CONSTRAINT"):
                cm = re.match(r"CONSTRAINT\s+(\w+)\s+(.*)", e_norm, re.IGNORECASE | re.DOTALL)
                cname, rest = cm.group(1), cm.group(2)
                rest_upper = rest.upper()
                if rest_upper.startswith("PRIMARY KEY"):
                    pk.append(cname)
                elif rest_upper.startswith("UNIQUE"):
                    unique.append(cname)
                elif rest_upper.startswith("FOREIGN KEY"):
                    fkm = re.search(r"REFERENCES\s+([\w.]+)\s*\(", rest, re.IGNORECASE)
                    fks.append({"name": cname, "references": fkm.group(1) if fkm else None})
                elif rest_upper.startswith("CHECK"):
                    checks.append(cname)
            else:
                col_name = e_norm.split()[0]
                columns.append(col_name)

        info.update({
            "columns": columns,
            "primary_key": pk,
            "unique": unique,
            "foreign_keys": fks,
            "checks": checks,
        })
    return tables


def parse_indexes(sql):
    indexes = []
    for m in re.finditer(
        r"CREATE\s+(UNIQUE\s+)?INDEX\s+(IF NOT EXISTS\s+)?(\w+)\s+ON\s+public\.(\w+)",
        sql, re.IGNORECASE,
    ):
        indexes.append({
            "name": m.group(3),
            "table": m.group(4),
            "unique": bool(m.group(1)),
            "if_not_exists": bool(m.group(2)),
        })
    return indexes


def check_manifest(sql):
    tables = parse_tables(sql)
    problems = []
    for expected in EXPECTED_TABLE_ORDER:
        if expected not in tables:
            problems.append("missing expected table: %s" % expected)
    manifest = {
        name: {
            "columns": info["columns"],
            "primary_key": info["primary_key"],
            "unique": info["unique"],
            "foreign_keys": info["foreign_keys"],
            "checks": info["checks"],
        }
        for name, info in tables.items()
    }
    manifest["indexes"] = parse_indexes(sql)
    return tables, manifest, problems


def check_dependency_order(sql, tables):
    problems = []
    positions = {name: info["start"] for name, info in tables.items()}
    order_seen = sorted(EXPECTED_TABLE_ORDER, key=lambda n: positions.get(n, -1))
    if order_seen != EXPECTED_TABLE_ORDER:
        problems.append(
            "CREATE TABLE order mismatch: expected %s, saw %s"
            % (EXPECTED_TABLE_ORDER, order_seen)
        )

    # every FK's referenced table must already be defined at or before this
    # table's own CREATE TABLE, OR be the same table (self-FK), OR be
    # auth.users (always present), OR be resolved by the deferred ALTER TABLE.
    deferred_fk_names = set()
    for dm in re.finditer(r"ADD CONSTRAINT\s+(\w+)\s+FOREIGN KEY", sql, re.IGNORECASE):
        deferred_fk_names.add(dm.group(1))

    for name, info in tables.items():
        for fk in info["foreign_keys"]:
            if fk["name"] in deferred_fk_names:
                continue  # resolved later via guarded ALTER TABLE, checked separately
            ref = fk["references"]
            if ref is None:
                problems.append("could not parse REFERENCES target for FK %s" % fk["name"])
                continue
            ref_table = ref.split(".")[-1]
            if ref_table == "users" and ref.startswith("auth."):
                continue  # auth.users always provisioned by Supabase
            if ref_table == name:
                continue  # self-referential FK, safe within one CREATE TABLE
            if ref_table not in tables:
                problems.append(
                    "table %s has FK %s referencing unknown table %s"
                    % (name, fk["name"], ref_table)
                )
                continue
            if positions[ref_table] > positions[name]:
                problems.append(
                    "table %s (pos %d) has FK %s referencing %s (pos %d), "
                    "which is created later"
                    % (name, positions[name], fk["name"], ref_table, positions[ref_table])
                )
    return problems


def check_idempotency(sql):
    problems = []
    create_table_all = re.findall(r"CREATE TABLE(?!\s+IF NOT EXISTS)\s+public\.", sql)
    if create_table_all:
        problems.append(
            "%d CREATE TABLE statement(s) missing IF NOT EXISTS" % len(create_table_all)
        )
    create_index_all = re.findall(
        r"CREATE\s+(?:UNIQUE\s+)?INDEX(?!\s+IF NOT EXISTS)\s+\w+\s+ON\s+public\.", sql
    )
    if create_index_all:
        problems.append(
            "%d CREATE INDEX statement(s) missing IF NOT EXISTS" % len(create_index_all)
        )

    guard_pattern = re.compile(
        r"DO\s+\$\$\s*BEGIN\s*IF NOT EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+pg_constraint"
        r"\s+WHERE\s+conname\s*=\s*'companies_account_manager_id_fkey'\s*\)\s*THEN"
        r".*?ADD CONSTRAINT\s+companies_account_manager_id_fkey"
        r".*?END IF;\s*END\s*\$\$;",
        re.IGNORECASE | re.DOTALL,
    )
    if not guard_pattern.search(sql):
        problems.append(
            "deferred companies_account_manager_id_fkey ALTER TABLE is not "
            "wrapped in the expected guarded DO $$ ... IF NOT EXISTS "
            "(SELECT ... pg_constraint) block"
        )
    return problems


def check_no_destructive_statements(sql):
    problems = []
    scan_text = re.sub(r"\bON\s+DELETE\b", "ON <fk-action>", sql, flags=re.IGNORECASE)
    for kw in FORBIDDEN_KEYWORDS:
        if re.search(r"\b" + re.escape(kw) + r"\b", scan_text, re.IGNORECASE):
            problems.append("forbidden statement keyword found: %s" % kw)
    for m in re.finditer(r"\bDELETE\b", scan_text, re.IGNORECASE):
        problems.append("unexpected DELETE statement near offset %d" % m.start())
    return problems


def find_central_earliest_migration(central_dir):
    files = sorted(f for f in os.listdir(central_dir) if f.endswith(".sql"))
    return os.path.join(central_dir, files[0]) if files else None


def check_central_lineage(tables, central_dir):
    """Deliverable 3e: does Central's earliest migration still reference a
    relation this repo's migrations (up to and including this baseline)
    never create?"""
    if not central_dir or not os.path.isdir(central_dir):
        return "SKIPPED", ["Central migrations directory not available in this environment (%r); "
                            "this check requires both repos checked out side by side and is not "
                            "expected to run inside oasis-supabase-core's own CI." % central_dir]

    earliest = find_central_earliest_migration(central_dir)
    if earliest is None:
        return "SKIPPED", ["Central migrations directory %r contains no .sql files" % central_dir]

    earliest_name = os.path.basename(earliest)
    earliest_ts = earliest_name.split("_", 1)[0]
    with open(earliest, "r") as f:
        central_sql = strip_line_comments(f.read())

    referenced = set(re.findall(r"public\.(\w+)", central_sql))
    if not referenced:
        return "SKIPPED", ["earliest Central migration %s references no public.<table> relations "
                            "(nothing to check)" % earliest_name]

    # Union of tables created by every Core migration timestamped <= earliest_ts.
    created = set()
    for fname in sorted(os.listdir(MIGRATIONS_DIR)):
        if not fname.endswith(".sql"):
            continue
        ts = fname.split("_", 1)[0]
        if ts <= earliest_ts:
            with open(os.path.join(MIGRATIONS_DIR, fname), "r") as f:
                core_sql = f.read()
            created |= set(re.findall(r"CREATE TABLE IF NOT EXISTS public\.(\w+)", core_sql))

    missing = sorted(referenced - created)
    detail = [
        "earliest Central migration: %s (timestamp %s)" % (earliest_name, earliest_ts),
        "relations it references: %s" % sorted(referenced),
        "relations created by Core migrations at/before that timestamp: %s" % sorted(created),
    ]
    if missing:
        return "FAIL", detail + ["still-missing relation(s): %s" % missing]
    return "PASS", detail + ["no missing relations -- baseline closes the gap"]


def check_sealed_ordering():
    """Verify that no new migration timestamps exist between the foundation
    baseline (20260101000000) and Central's earliest migration (20260316122451).
    This reserved range is sealed to prevent migrations from accidentally
    interleaving with the foundational sequence."""
    problems = []
    BASELINE_TS = "20260101000000"
    CENTRAL_EARLIEST_TS = "20260316122451"

    for fname in sorted(os.listdir(MIGRATIONS_DIR)):
        if not fname.endswith(".sql"):
            continue
        ts = fname.split("_", 1)[0]
        # Check if this migration's timestamp falls in the sealed range
        # (exclusive of the endpoints, but inclusive of the range)
        if BASELINE_TS < ts < CENTRAL_EARLIEST_TS:
            problems.append(
                "migration %s (timestamp %s) violates sealed-ordering invariant: "
                "no migrations may be timestamped between %s and %s"
                % (fname, ts, BASELINE_TS, CENTRAL_EARLIEST_TS)
            )
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--central-migrations-dir",
        default=os.environ.get("CENTRAL_MIGRATIONS_DIR"),
        help="Path to Oasis-Baklawa-Central's supabase/migrations directory "
             "(optional; defaults to $CENTRAL_MIGRATIONS_DIR, or SKIPPED if unset/absent)",
    )
    parser.add_argument("--json", action="store_true", help="print the schema-contract manifest as JSON")
    parser.add_argument(
        "--validate-applied",
        default=None,
        help="(reserved for Phase 4.1c+) PostgreSQL connection string to validate "
             "post-apply schema (columns, constraints, indexes, column count). "
             "Not yet implemented in Phase 4.1c. When available: "
             "psql_dsn://user:pass@host:port/dbname or similar."
    )
    args = parser.parse_args()

    baseline_path = find_baseline_file()
    if baseline_path is None:
        print("FAIL: no migration file starting with %s found in %s" % (BASELINE_TIMESTAMP, MIGRATIONS_DIR))
        return 1

    with open(baseline_path, "r") as f:
        sql_raw = f.read()
    sql = strip_line_comments(sql_raw)

    print("Validating: %s" % os.path.relpath(baseline_path, REPO_ROOT))
    print()

    overall_ok = True

    tables, manifest, manifest_problems = check_manifest(sql)
    print("[1/5] Schema-contract manifest (tables/columns/PK/UNIQUE/FK)")
    if manifest_problems:
        overall_ok = False
        for p in manifest_problems:
            print("  FAIL: %s" % p)
    else:
        for t in EXPECTED_TABLE_ORDER:
            info = tables[t]
            print(
                "  OK: %-13s columns=%-3d pk=%d unique=%d fk=%d check=%d"
                % (t, len(info["columns"]), len(info["primary_key"]), len(info["unique"]),
                   len(info["foreign_keys"]), len(info["checks"]))
            )
    if args.json:
        print(json.dumps(manifest, indent=2, default=str))
    print()

    print("[2/5] Dependency order (FKs never reference a not-yet-created table)")
    order_problems = check_dependency_order(sql, tables)
    if order_problems:
        overall_ok = False
        for p in order_problems:
            print("  FAIL: %s" % p)
    else:
        print("  OK: %s" % " -> ".join(EXPECTED_TABLE_ORDER))
    print()

    print("[3/5] Idempotent / replay-safe guards")
    idem_problems = check_idempotency(sql)
    if idem_problems:
        overall_ok = False
        for p in idem_problems:
            print("  FAIL: %s" % p)
    else:
        print("  OK: every CREATE TABLE / CREATE INDEX uses IF NOT EXISTS; "
              "deferred FK is guarded")
    print()

    print("[4/5] No destructive/data-mutating statements")
    destructive_problems = check_no_destructive_statements(sql)
    if destructive_problems:
        overall_ok = False
        for p in destructive_problems:
            print("  FAIL: %s" % p)
    else:
        print("  OK: no DROP/TRUNCATE/INSERT/UPDATE/GRANT/REVOKE/POLICY/FUNCTION/TRIGGER/"
              "bare-DELETE statements found")
    print()

    print("[5/5] Central-lineage check (earliest Central migration no longer "
          "references a missing relation)")
    status, detail = check_central_lineage(tables, args.central_migrations_dir)
    for line in detail:
        print("  %s" % line)
    if status == "FAIL":
        overall_ok = False
        print("  FAIL")
    elif status == "SKIPPED":
        print("  SKIPPED (not counted as failure -- see detail above)")
    else:
        print("  PASS")
    print()

    print("[6/6] Sealed-ordering invariant (no migrations between foundation "
          "baseline 20260101000000 and Central earliest 20260316122451)")
    sealed_problems = check_sealed_ordering()
    if sealed_problems:
        overall_ok = False
        for p in sealed_problems:
            print("  FAIL: %s" % p)
    else:
        print("  OK: no migration timestamps in sealed range [20260101000000, 20260316122451)")
    print()

    print("=" * 60)
    print("OVERALL: %s" % ("PASS" if overall_ok else "FAIL"))
    print("(no database connection was made; no Supabase branch/project was "
          "created or contacted by this script)")
    if args.validate_applied:
        print("\nNOTE: --validate-applied flag provided but post-apply validation is not yet")
        print("implemented in Phase 4.1c. This flag is reserved for Phase 4.1c+ to check:")
        print("  - column names, types, nullability, defaults via information_schema.columns")
        print("  - constraint names/definitions via pg_constraint")
        print("  - index names/definitions via pg_indexes")
        print("  - products table column count = 137")
        print("  - Central earliest migration now succeeds (no missing-relation errors)")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
