#!/usr/bin/env bash
# Regression for rollback source capture. A rollback archive must restore a complete,
# hash-verified import closure or the capture must fail and leave no output behind.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
real_repo="$PWD"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sha() { sha256sum "$1" | awk '{print $1}'; }

# --- synthetic repo holding the capture tooling and one historical type-only file -----------
syn="$tmp/syn"
mkdir -p "$syn/scripts" "$syn/supabase/functions/demo-types"
git -C "$syn" init -q
git -C "$syn" config user.email t@example.invalid
git -C "$syn" config user.name t
cp scripts/capture-live-edge-function-rollback-artifacts.sh \
  scripts/edge-function-source-manifest.py \
  scripts/edge-function-rollback-completion.py "$syn/scripts/"
printf 'export type Kind = "a" | "b";\n' >"$syn/supabase/functions/demo-types/types.ts"
git -C "$syn" add -A
git -C "$syn" commit -q -m "historical type-only source"
prov="$(git -C "$syn" rev-parse HEAD)"
types_sha="$(sha "$syn/supabase/functions/demo-types/types.ts")"

bundle="$(printf 'bundle' | sha256sum | awk '{print $1}')"
jq -n --arg b "$bundle" '{ezbr_sha256:$b,version:7}' >"$tmp/live.json"

# Download tree as the platform returns it: the type-only module is omitted.
make_download() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/demo-fn" "$dir/_shared"
  cat >"$dir/demo-fn/index.ts" <<'TS'
import type { Kind } from "../demo-types/types.ts";
import { dep } from "../_shared/dep.ts";
export const run = (k: Kind) => dep(k);
TS
  printf 'export const dep = (v: string) => v;\n' >"$dir/_shared/dep.ts"
}

make_pin() {
  local download="$1" out="$2" commit="${3:-$prov}" pin_types_sha="${4:-$types_sha}"
  jq -n \
    --arg b "$bundle" --arg commit "$commit" --arg ts "$pin_types_sha" \
    --arg idx "$(sha "$download/demo-fn/index.ts")" \
    --arg dep "$(sha "$download/_shared/dep.ts")" \
    '{liveVersion:7,liveBundleSha256:$b,provenanceCommit:$commit,
      retrievedFiles:[{path:"_shared/dep.ts",sha256:$dep},{path:"demo-fn/index.ts",sha256:$idx}],
      completions:[{path:"demo-types/types.ts",sha256:$ts,importedBy:"demo-fn/index.ts",kind:"type-only"}]}' >"$out"
}

# run_capture <download> <out_prefix> [pin] ; sets rc and err
run_capture() {
  local download="$1" prefix="$2" pin="${3:-}"
  set +e
  (cd "$syn" && bash scripts/capture-live-edge-function-rollback-artifacts.sh \
    "$download" demo-fn "$tmp/live.json" "$prefix.manifest.json" "$prefix.tar.gz" ${pin:+"$pin"}) \
    >"$prefix.out" 2>"$prefix.err"
  rc=$?
  set -e
}

expect_fail() { # <label> <stderr pattern> ; uses rc/err from the last run_capture, prefix in $1 dir
  local label="$1" pattern="$2" prefix="$3"
  [[ "$rc" -ne 0 ]] || fail "$label: capture unexpectedly succeeded"
  grep -Eq "$pattern" "$prefix.err" || { cat "$prefix.err" >&2; fail "$label: expected /$pattern/"; }
  [[ ! -e "$prefix.manifest.json" && ! -e "$prefix.tar.gz" ]] \
    || fail "$label: failed capture left output behind"
}

dl="$tmp/dl"
make_download "$dl"

# 1. Misleading success: an omitted type-only module with no pin must fail, never fall back
#    to reporting the live bundle hash as the source closure.
p="$tmp/c1"; : >"$p.manifest.json"; : >"$p.tar.gz"   # stale output must be removed
run_capture "$dl" "$p"
[[ "$rc" -ne 0 ]] || fail "incomplete download without pin succeeded"
grep -q "unable to resolve local import" "$p.err" || fail "missing import not reported"
[[ ! -e "$p.manifest.json" && ! -e "$p.tar.gz" ]] || fail "stale capture output survived a failed run"

# 2. A missing value dependency can never be completed from history.
dl_missing="$tmp/dl-missing"; make_download "$dl_missing"; rm "$dl_missing/_shared/dep.ts"
make_pin "$dl" "$tmp/pin-ok.json"
run_capture "$dl_missing" "$tmp/c2" "$tmp/pin-ok.json"
expect_fail "missing value dependency" "does not match pinned file set|unable to resolve" "$tmp/c2"

# 3. Valid pinned completion: succeeds, closure is computed (not the bundle hash), provenance recorded.
run_capture "$dl" "$tmp/c3" "$tmp/pin-ok.json"
[[ "$rc" -eq 0 ]] || { cat "$tmp/c3.err" >&2; fail "valid pinned completion failed"; }
jq -e --arg b "$bundle" --arg ts "$types_sha" --arg prov "$prov" '
  .captureMode == "live_download_with_pinned_historical_completion"
  and .closureSha256 != $b and .bundleSha256 == $b and .fileCount == 3
  and .completedPaths == ["demo-types/types.ts"]
  and ([.files[] | select(.path == "demo-types/types.ts")][0].origin
       | .origin == "pinned_historical_git" and .provenanceCommit == $prov)
  and ([.files[] | select(.path != "demo-types/types.ts") | .origin.origin] | all(. == "live_api_download"))
  and ([.files[] | select(.path == "demo-types/types.ts")][0].sha256 == $ts)' \
  "$tmp/c3.manifest.json" >/dev/null || fail "completed manifest lacks computed closure or provenance"
tar -tzf "$tmp/c3.tar.gz" | grep -Fxq 'functions/demo-types/types.ts' || fail "archive lacks completed file"
[[ ! -e "$dl/demo-types/types.ts" ]] || fail "capture modified the downloaded input tree"

# 4. Complete download needs no pin and is labelled as live-only.
dl_full="$tmp/dl-full"; make_download "$dl_full"; mkdir -p "$dl_full/demo-types"
cp "$syn/supabase/functions/demo-types/types.ts" "$dl_full/demo-types/types.ts"
run_capture "$dl_full" "$tmp/c4"
[[ "$rc" -eq 0 ]] || { cat "$tmp/c4.err" >&2; fail "complete download failed"; }
jq -e '.captureMode == "live_download_closure" and .completedPaths == []
       and ([.files[].origin.origin] | all(. == "live_api_download"))' \
  "$tmp/c4.manifest.json" >/dev/null || fail "complete download mislabelled"

# 5. Pin rejections: every one fails closed and leaves nothing behind.
make_pin "$dl" "$tmp/pin-badhash.json" "$prov" "$(printf x | sha256sum | awk '{print $1}')"
run_capture "$dl" "$tmp/c5a" "$tmp/pin-badhash.json"
expect_fail "completion bytes differ from pin" "has sha256" "$tmp/c5a"

make_pin "$dl" "$tmp/pin-nocommit.json" "0000000000000000000000000000000000000000"
run_capture "$dl" "$tmp/c5b" "$tmp/pin-nocommit.json"
expect_fail "provenance commit absent" "not present in this checkout" "$tmp/c5b"

dl_drift="$tmp/dl-drift"; make_download "$dl_drift"; printf '// drift\n' >>"$dl_drift/_shared/dep.ts"
run_capture "$dl_drift" "$tmp/c5c" "$tmp/pin-ok.json"
expect_fail "live file differs from pin" "differs from pinned" "$tmp/c5c"

jq '.liveVersion = 8' "$tmp/pin-ok.json" >"$tmp/pin-ver.json"
run_capture "$dl" "$tmp/c5d" "$tmp/pin-ver.json"
expect_fail "pin for another live version" "does not describe the live worker" "$tmp/c5d"

dl_partial="$tmp/dl-partial"; make_download "$dl_partial"; rm "$dl_partial/_shared/dep.ts"
run_capture "$dl_partial" "$tmp/c5e" "$tmp/pin-ok.json"
expect_fail "incomplete download vs pinned set" "does not match pinned file set" "$tmp/c5e"

dl_value="$tmp/dl-value"; make_download "$dl_value"
printf 'import { Kind as K } from "../demo-types/types.ts";\nexport const v: K | undefined = undefined;\n' \
  >>"$dl_value/demo-fn/index.ts"
make_pin "$dl_value" "$tmp/pin-value.json"
run_capture "$dl_value" "$tmp/c5f" "$tmp/pin-value.json"
expect_fail "value import cannot be completed" "value import" "$tmp/c5f"

dl_present="$tmp/dl-present"; make_download "$dl_present"; mkdir -p "$dl_present/demo-types"
cp "$syn/supabase/functions/demo-types/types.ts" "$dl_present/demo-types/types.ts"
run_capture "$dl_present" "$tmp/c5g" "$tmp/pin-ok.json"
expect_fail "completion already returned live" "does not match pinned file set" "$tmp/c5g"

# 5i. A self-contradicting pin (same path both "retrieved" and "completed") is rejected.
dl_contra="$tmp/dl-contra"; make_download "$dl_contra"; mkdir -p "$dl_contra/demo-types"
cp "$syn/supabase/functions/demo-types/types.ts" "$dl_contra/demo-types/types.ts"
jq --arg ts "$types_sha" '.retrievedFiles += [{path:"demo-types/types.ts",sha256:$ts}]' \
  "$tmp/pin-ok.json" >"$tmp/pin-contra.json"
run_capture "$dl_contra" "$tmp/c5i" "$tmp/pin-contra.json"
expect_fail "completion returned by live download" "not an omission" "$tmp/c5i"

# 5j. importedBy must name a file that actually imports the omitted module.
jq '.completions[0].importedBy = "_shared/dep.ts"' "$tmp/pin-ok.json" >"$tmp/pin-importer.json"
run_capture "$dl" "$tmp/c5j" "$tmp/pin-importer.json"
expect_fail "importedBy does not import the module" "has no type-only import" "$tmp/c5j"

# 5h. The capture itself must re-verify what it archived: a tar that silently drops a file
#     must fail the capture rather than ship an archive that cannot restore.
mkdir -p "$tmp/shim"
real_tar="$(command -v tar)"
cat >"$tmp/shim/tar" <<SH
#!/usr/bin/env bash
dir=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-C" ]] && dir="\$a"; prev="\$a"; done
[[ -n "\$dir" ]] && rm -f "\$dir/functions/_shared/dep.ts"
exec "$real_tar" "\$@"
SH
chmod +x "$tmp/shim/tar"
PATH="$tmp/shim:$PATH" run_capture "$dl" "$tmp/c5h" "$tmp/pin-ok.json"
expect_fail "archive silently dropped a file" "ROLLBACK_CAPTURE_FAILED" "$tmp/c5h"

# 6. Restoration failures: verify-archive must reject every archive that would not restore.
good_tar="$tmp/c3.tar.gz"; good_manifest="$tmp/c3.manifest.json"
verify() { python3 scripts/edge-function-rollback-completion.py verify-archive --tarball "$1" --manifest "$2"; }
verify "$good_tar" "$good_manifest" >/dev/null 2>&1 || fail "verify-archive rejected a good archive"

tamper() { # <name> <python mutator body using t_in/t_out helpers>
  python3 -I - "$good_tar" "$tmp/t-$1.tar.gz" "$1" <<'PY'
import io, sys, tarfile
src, dst, mode = sys.argv[1:4]
with tarfile.open(src, "r:gz") as zin, tarfile.open(dst, "w:gz") as zout:
    for m in zin.getmembers():
        data = zin.extractfile(m).read() if m.isreg() else None
        if mode == "missing" and m.name.endswith("_shared/dep.ts"):
            continue
        if mode == "duplicate" and m.name.endswith("_shared/dep.ts"):
            bad = tarfile.TarInfo(m.name); body = b"export const dep = () => 'evil';\n"; bad.size = len(body)
            zout.addfile(bad, io.BytesIO(body))   # earlier bad entry, original follows
        if mode == "modified" and m.name.endswith("_shared/dep.ts"):
            data = bytes([data[0] ^ 1]) + data[1:]   # same length, different bytes
        if mode == "grown" and m.name.endswith("_shared/dep.ts"):
            data = data + b"// tampered\n"; m.size = len(data)
        zout.addfile(m, io.BytesIO(data) if data is not None else None)
    if mode == "extra":
        info = tarfile.TarInfo("functions/_shared/extra.ts"); body = b"export {};\n"; info.size = len(body)
        zout.addfile(info, io.BytesIO(body))
    if mode == "traversal":
        info = tarfile.TarInfo("functions/../evil.ts"); body = b"x"; info.size = len(body)
        zout.addfile(info, io.BytesIO(body))
    if mode == "fifo":
        info = tarfile.TarInfo("functions/pipe.ts"); info.type = tarfile.FIFOTYPE
        zout.addfile(info)
    if mode == "symlink":
        info = tarfile.TarInfo("functions/link.ts"); info.type = tarfile.SYMTYPE; info.linkname = "/etc/passwd"
        zout.addfile(info)
PY
}
for mode in missing modified grown duplicate extra traversal symlink fifo; do
  tamper "$mode"
  if verify "$tmp/t-$mode.tar.gz" "$good_manifest" >/dev/null 2>"$tmp/v-$mode.err"; then
    fail "verify-archive accepted a $mode archive"
  fi
  grep -q "ROLLBACK_CAPTURE_FAILED" "$tmp/v-$mode.err" || fail "$mode archive failed without a capture error"
done

printf 'not a tarball' >"$tmp/junk.tar.gz"
if verify "$tmp/junk.tar.gz" "$good_manifest" >/dev/null 2>&1; then fail "verify-archive accepted a non-tarball"; fi

jq '.closureSha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$good_manifest" >"$tmp/m-closure.json"
if verify "$good_tar" "$tmp/m-closure.json" >/dev/null 2>&1; then fail "closure mismatch accepted"; fi

# Per-file records are verified on their own, independent of the closure comparison:
# a wrong per-file hash or size in the manifest (archive intact) must be rejected.
jq '(.files[] | select(.path == "_shared/dep.ts") | .sha256) = "1111111111111111111111111111111111111111111111111111111111111111"' \
  "$good_manifest" >"$tmp/m-filehash.json"
if verify "$good_tar" "$tmp/m-filehash.json" >"$tmp/v-filehash.out" 2>"$tmp/v-filehash.err"; then fail "wrong per-file hash accepted"; fi
grep -q "sha256 differs" "$tmp/v-filehash.err" || fail "per-file hash mismatch not reported as such"
jq '(.files[] | select(.path == "_shared/dep.ts") | .size) += 1' "$good_manifest" >"$tmp/m-filesize.json"
if verify "$good_tar" "$tmp/m-filesize.json" >"$tmp/v-filesize.out" 2>"$tmp/v-filesize.err"; then fail "wrong per-file size accepted"; fi
grep -q "size differs" "$tmp/v-filesize.err" || fail "per-file size mismatch not reported as such"

# An orphan archived file, listed in the manifest with the right closure of the reachable
# files, is not covered by the import closure and must be rejected.
python3 -I - "$good_tar" "$tmp/orphan.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as zin, tarfile.open(sys.argv[2], "w:gz") as zout:
    for m in zin.getmembers():
        zout.addfile(m, zin.extractfile(m) if m.isreg() else None)
    info = tarfile.TarInfo("functions/_shared/orphan.ts"); body = b"export {};\n"; info.size = len(body)
    zout.addfile(info, io.BytesIO(body))
PY
jq --arg h "$(printf 'export {};\n' | sha256sum | awk '{print $1}')" \
  '.files += [{path:"_shared/orphan.ts",sha256:$h,size:11}]' "$good_manifest" >"$tmp/m-orphan.json"
if verify "$tmp/orphan.tar.gz" "$tmp/m-orphan.json" >"$tmp/v-orphan.out" 2>"$tmp/v-orphan.err"; then fail "orphan archived file accepted"; fi
grep -q "does not cover every archived file" "$tmp/v-orphan.err" || fail "orphan not reported as uncovered"

# An archive that agrees with its manifest hashes but is not an import closure must still fail.
mkdir -p "$tmp/partial/functions/demo-fn" "$tmp/partial/functions/_shared"
cp "$dl/demo-fn/index.ts" "$tmp/partial/functions/demo-fn/"; cp "$dl/_shared/dep.ts" "$tmp/partial/functions/_shared/"
tar -C "$tmp/partial" -czf "$tmp/partial.tar.gz" functions
jq -n --arg i "$(sha "$dl/demo-fn/index.ts")" --arg d "$(sha "$dl/_shared/dep.ts")" \
  --argjson is "$(wc -c <"$dl/demo-fn/index.ts")" --argjson ds "$(wc -c <"$dl/_shared/dep.ts")" \
  '{function:"demo-fn",closureSha256:"x",files:[{path:"demo-fn/index.ts",sha256:$i,size:$is},{path:"_shared/dep.ts",sha256:$d,size:$ds}]}' \
  >"$tmp/m-partial.json"
if verify "$tmp/partial.tar.gz" "$tmp/m-partial.json" >"$tmp/v-partial.out" 2>"$tmp/v-partial.err"; then
  fail "hash-consistent but non-closed archive accepted"
fi
grep -q "complete import closure" "$tmp/v-partial.err" || fail "non-closed archive not reported as such"

# 7. Real v20 data: the five files the platform returned, reconstructed from the commit whose
#    files are byte-identical to the live bundle, must complete to the reviewed closure.
pin_real="scripts/lib/whatsapp-packet-ai-worker-v20-rollback-completion.json"
real_commit="$(jq -er '.provenanceCommit' "$pin_real")"
git cat-file -e "${real_commit}^{commit}" 2>/dev/null \
  || fail "provenance commit $real_commit missing; this test needs full git history (fetch-depth: 0)"
real_dl="$tmp/real-dl"; mkdir -p "$real_dl"
while IFS= read -r rel; do
  mkdir -p "$real_dl/$(dirname "$rel")"
  git show "${real_commit}:supabase/functions/$rel" >"$real_dl/$rel"
done < <(jq -r '.retrievedFiles[].path' "$pin_real")
jq -n --arg b "$(jq -er '.liveBundleSha256' "$pin_real")" --argjson v "$(jq -er '.liveVersion' "$pin_real")" \
  '{ezbr_sha256:$b,version:$v}' >"$tmp/live-real.json"
bash scripts/capture-live-edge-function-rollback-artifacts.sh \
  "$real_dl" whatsapp-packet-ai-worker "$tmp/live-real.json" \
  "$tmp/real.manifest.json" "$tmp/real.tar.gz" "$pin_real"
jq -e --arg c "$(jq -er '.expectedClosureSha256' "$pin_real")" \
  '.closureSha256 == $c and .fileCount == 6 and .completedPaths == ["whatsapp-content-interpret/types.ts"]' \
  "$tmp/real.manifest.json" >/dev/null || fail "real v20 capture did not reproduce the reviewed closure"
if bash scripts/capture-live-edge-function-rollback-artifacts.sh \
  "$real_dl" whatsapp-packet-ai-worker "$tmp/live-real.json" \
  "$tmp/real2.manifest.json" "$tmp/real2.tar.gz" >/dev/null 2>&1; then
  fail "real v20 download without the completion pin must fail"
fi

echo "capture-live-edge-function-rollback-artifacts regression passed."
