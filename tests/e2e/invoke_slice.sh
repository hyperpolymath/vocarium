#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The M1 honest gate (ADR-0002): prove the invoke slice end-to-end.
#
# What this proves, in order:
#   0. The toolchain is exactly what we pinned (hard-fail if absent/wrong —
#      proof-gates-cannot-fail doctrine: a gate that silently skips is worse
#      than no gate).
#   1. Unit tests pass (zig build test).
#   2. The canonical store ingests cleanly.
#   3. USE-RELATIVITY: the same stored trope yields OPPOSITE tropecheck
#      verdicts under two use-models (casual-note -> exit 0 AND
#      critical-paraphrase -> exit 1, witness edge named). Neither an empty
#      store, a stubbed method, nor a broken emitter can pass both.
#   4. An unwarranted edge is refused at the store door (exit 2).
set -euo pipefail
cd "$(dirname "$0")/../.."

ZIG_EXPECTED="$(awk '$1=="zig"{print $2}' .tool-versions)"
TROPECHECK_PIN="69221ad6bec0c9286cb5c917edfad281e7e0089e"

fail() { echo "GATE FAIL: $*" >&2; exit 1; }

# --- 0. tool-pin hard asserts (BEFORE any test) -----------------------------
command -v zig >/dev/null || fail "zig not installed (need exactly ${ZIG_EXPECTED})"
ZIG_ACTUAL="$(zig version)"
[ "$ZIG_ACTUAL" = "$ZIG_EXPECTED" ] || fail "zig version skew: have ${ZIG_ACTUAL}, .tool-versions pins ${ZIG_EXPECTED}"

if [ -z "${TROPECHECK_BIN:-}" ]; then
  command -v cargo >/dev/null || fail "cargo not installed (needed to build tropecheck-rs at pin ${TROPECHECK_PIN})"
  command -v git >/dev/null || fail "git not installed"
  TC_DIR=".gate-tools/trope-checker"
  if [ ! -x "${TC_DIR}/src/rust/target/release/tropecheck-rs" ] || \
     [ "$(git -C "${TC_DIR}" rev-parse HEAD 2>/dev/null)" != "${TROPECHECK_PIN}" ]; then
    rm -rf "${TC_DIR}"
    git clone -q https://github.com/hyperpolymath/trope-checker "${TC_DIR}" || fail "cannot clone trope-checker"
    git -C "${TC_DIR}" checkout -q "${TROPECHECK_PIN}" || fail "cannot checkout tropecheck pin ${TROPECHECK_PIN}"
    cargo build --quiet --release --manifest-path "${TC_DIR}/src/rust/Cargo.toml" || fail "tropecheck-rs build failed"
  fi
  TROPECHECK_BIN="${TC_DIR}/src/rust/target/release/tropecheck-rs"
fi
[ -x "$TROPECHECK_BIN" ] || fail "tropecheck binary not executable: ${TROPECHECK_BIN}"

# --- 1. unit tests ----------------------------------------------------------
zig build test || fail "zig build test failed"
zig build || fail "zig build failed"
VOC=zig-out/bin/voc
[ -x "$VOC" ] || fail "voc binary missing after build"

# --- 2. canonical ingest ----------------------------------------------------
"$VOC" ingest examples/vocarium-ingest.jsonl || fail "canonical fixture failed ingest (exit $?)"

# --- 3. use-relativity ------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$VOC" invoke --store examples/vocarium-ingest.jsonl --use-model casual-note t_real > "$TMP/casual.json" \
  || fail "voc invoke (casual-note) failed"
if "$TROPECHECK_BIN" "$TMP/casual.json" > "$TMP/casual.out"; then
  grep -q '^p-sufficient' "$TMP/casual.out" || fail "casual-note: exit 0 but verdict line missing"
else
  fail "casual-note must be p-sufficient (exit 0), got exit $?"
fi

"$VOC" invoke --store examples/vocarium-ingest.jsonl --use-model critical-paraphrase t_real > "$TMP/critical.json" \
  || fail "voc invoke (critical-paraphrase) failed"
if "$TROPECHECK_BIN" "$TMP/critical.json" > "$TMP/critical.out"; then
  fail "critical-paraphrase must be p-insufficient (exit 1), got exit 0 — use-relativity is broken"
else
  rc=$?
  [ "$rc" -eq 1 ] || fail "critical-paraphrase: expected exit 1, got ${rc}"
  grep -q 'witness=e_paraphrase' "$TMP/critical.out" || fail "insufficient verdict lacks the witness edge"
fi

# --- 4. unwarranted edge refused -------------------------------------------
if "$VOC" invoke --store tests/e2e/fixtures/unwarranted.jsonl --use-model casual-note t_b > /dev/null 2> "$TMP/neg.err"; then
  fail "unwarranted edge was ACCEPTED — the store door is open"
else
  rc=$?
  [ "$rc" -eq 2 ] || fail "unwarranted edge: expected validation exit 2, got ${rc}"
  grep -q 'unknown warrant' "$TMP/neg.err" || fail "refusal did not name the warrant fault"
fi

echo "GATE PASS: invoke slice proven (use-relativity + warrant door + unit tests)"
