#!/usr/bin/env python3
"""No-secret-output regressions for approved Core Edge origin metadata."""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/require-admin-provision-origin-digest.rb"


def case(title, inventory, allowed, diagnostic=None):
    with tempfile.TemporaryDirectory(prefix="staff-origin-inventory-") as d:
        source, out = pathlib.Path(d) / "inventory.json", pathlib.Path(d) / "digest.txt"
        source.write_text(json.dumps(inventory))
        p = subprocess.run(
            ["ruby", str(HELPER), str(source), str(out)],
            capture_output=True, text=True, check=False,
        )
        if (p.returncode == 0) != allowed:
            raise AssertionError(f"{title}: unexpected status {p.returncode}: {p.stderr[:200]}")
        if diagnostic and diagnostic not in (p.stderr + p.stdout):
            raise AssertionError(f"{title}: no expected diagnostic")
        if "SHOULD_NEVER_BE_PRINTED" in p.stdout + p.stderr:
            raise AssertionError(f"{title}: origin metadata leaked into logs")
        if allowed:
            assert out.read_text() == ("f" * 64 + "\n"), title
        else:
            assert not out.exists(), title
        print(f"{title}: {'accepted' if allowed else 'rejected'}")


case("one correctly named digest", [
    {"name": "OTHER", "value": "SHOULD_NEVER_BE_PRINTED"},
    {"name": "ADMIN_PROVISION_ALLOWED_ORIGIN", "value": "f" * 64}], True)
case("missing origin", [{"name": "OTHER", "value": "SHOULD_NEVER_BE_PRINTED"}], False, "missing")
case("empty inventory", [], False, "missing")
case("duplicate origin", [
    {"name": "ADMIN_PROVISION_ALLOWED_ORIGIN", "value": "f" * 64},
    {"name": "ADMIN_PROVISION_ALLOWED_ORIGIN", "value": "f" * 64}], False, "duplicate")
case("unexpected response envelope", {
    "secrets": [{"name": "ADMIN_PROVISION_ALLOWED_ORIGIN", "value": "f" * 64}]},
    False, "not the expected array")
case("missing entry name", [{"value": "f" * 64}], False, "not the expected array")
case("cleartext instead of SHA-256 digest", [{
    "name": "ADMIN_PROVISION_ALLOWED_ORIGIN",
    "value": "https://oasis-baklawa-central.vercel.app"}], False, "SHA-256")
case("absent value", [{"name": "ADMIN_PROVISION_ALLOWED_ORIGIN"}], False, "SHA-256")
case("nonhex digest", [{"name": "ADMIN_PROVISION_ALLOWED_ORIGIN", "value": "z" * 64}],
     False, "SHA-256")
print("STAFF ORIGIN INVENTORY CONTRACT: one positive, eight negative cases passed")
